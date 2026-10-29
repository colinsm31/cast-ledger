-- String jobs: stock reservation, status rules, consume on completion,
-- cancellation, and who entered / completed / delivered / cancelled.
begin;
\ir helpers/setup.psql

select plan(20);

insert into customer_rackets (id, customer_id, brand, model, barcode) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'TestBrand', 'Frame A', 'TAG-A'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'TestBrand', 'Frame B', 'TAG-B');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- Job 1: same string for mains and crosses (reserves one unit, not two).
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 55, 53, 30);
-- Job 2 (another racquet): will be cancelled.
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000f2',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 30);

select is((select entered_by from string_jobs where id = '00000000-0000-0000-0000-000000000f01'),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'a new job records who entered it');
select results_eq(
  $$ select on_hand, committed, available from product_available
      where product_id = '00000000-0000-0000-0000-0000000000b1' $$,
  $$ values (10::numeric, 2, 8::numeric) $$,
  'each entered job reserves one unit of its string (mains = crosses counts once)');

select throws_like(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f01', 'delivered') $$,
  '%Cannot move a string job from "entered" to "delivered"%', 'status cannot skip a step');
select throws_like(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f01', 'bogus') $$,
  '%Invalid status%', 'unknown status is rejected');
select throws_like(
  $$ select advance_string_job('00000000-0000-0000-0000-00000000dead', 'complete') $$,
  '%Unknown string job%', 'unknown job is rejected');

-- Complete job 1 as the admin, so attribution is visibly per action.
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
-- A job needs a stringer before it's complete (0051).
update string_jobs set strung_by = 'Test Stringer' where id = '00000000-0000-0000-0000-000000000f01';
select is(advance_string_job('00000000-0000-0000-0000-000000000f01', 'complete'), 'complete',
          'entered → complete');
select isnt((select completed_at from string_jobs where id = '00000000-0000-0000-0000-000000000f01'),
            null, 'completion time is recorded');
select is((select completed_by from string_jobs where id = '00000000-0000-0000-0000-000000000f01'),
          '00000000-0000-0000-0000-0000000000a2'::uuid, 'completion records who completed it');
select results_eq(
  $$ select txn_type, qty, user_id from inventory_txns
      where product_id = '00000000-0000-0000-0000-0000000000b1' and txn_type = 'consume' $$,
  $$ values ('consume'::text, -1::numeric(14,3), '00000000-0000-0000-0000-0000000000a2'::uuid) $$,
  'completing consumes one unit of the distinct string, attributed to the completer');
select results_eq(
  $$ select on_hand, committed, available from product_available
      where product_id = '00000000-0000-0000-0000-0000000000b1' $$,
  $$ values (9::numeric, 1, 8::numeric) $$,
  'the reservation becomes a real stock reduction');

select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok(
  $$ select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":30}]'::jsonb,
                        '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":30}]'::jsonb, null) $$,
  'the customer pays for the job at pickup');
select is(advance_string_job('00000000-0000-0000-0000-000000000f01', 'delivered'), 'delivered',
          'complete → delivered');
select is((select delivered_by from string_jobs where id = '00000000-0000-0000-0000-000000000f01'),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'delivery records who handed it over');
select throws_like(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f01', 'complete') $$,
  '%Cannot move%', 'status cannot go backwards');

-- Cancel job 2.
select throws_like(
  $$ select cancel_string_job('00000000-0000-0000-0000-000000000f01') $$,
  '%Only an entered job can be cancelled%', 'a delivered job cannot be cancelled');
select is(cancel_string_job('00000000-0000-0000-0000-000000000f02'), 'cancelled', 'an entered job can be cancelled');
select results_eq(
  $$ select status, cancelled_by, cancelled_at is not null
       from string_jobs where id = '00000000-0000-0000-0000-000000000f02' $$,
  $$ values ('cancelled'::text, '00000000-0000-0000-0000-0000000000a1'::uuid, true) $$,
  'cancellation records who and when');
select is((select committed from product_available where product_id = '00000000-0000-0000-0000-0000000000b1'),
          0, 'cancelling releases the reservation');
select is((select on_hand from product_stock where product_id = '00000000-0000-0000-0000-0000000000b1'),
          9::numeric, 'cancelling consumes nothing');
select throws_like(
  $$ select cancel_string_job('00000000-0000-0000-0000-00000000dead') $$,
  '%Unknown string job%', 'cancelling an unknown job is rejected');

select * from finish();
rollback;
