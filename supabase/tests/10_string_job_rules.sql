-- String-job lifecycle rules enforced by the server (code review #2, #3, #10, #20):
-- explicit status changes, no cancelling a paid job, paid before delivery,
-- strings fixed once strung, one open job per active racquet, qty 1 job lines.
begin;
\ir helpers/setup.psql

select plan(31);

select tests.create_staff('00000000-0000-0000-0000-0000000000a3', 'pending@test.local', 'pending');

insert into customer_rackets (id, customer_id, model, is_active) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Frame A', true),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'Frame B', true),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000c1', 'Frame C', true),
  ('00000000-0000-0000-0000-0000000000f4', '00000000-0000-0000-0000-0000000000c1', 'Retired Frame', false);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- Job 1 (Frame A): strung, then paid and delivered.
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 55, 53, 30);
-- Job 2 (Frame B): prepaid while still entered.
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 30);
-- Job 3 (Frame C): cancelled.
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f03', '00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 30);

-- ---------------------------------------------------------------------------
-- Completing: one step at a time, and only once (#3)
-- ---------------------------------------------------------------------------
select is(advance_string_job('00000000-0000-0000-0000-000000000f01', 'complete'), 'complete',
          'an entered job can be completed');
select throws_like(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f01', 'complete') $$,
  '%Cannot move a string job from "complete" to "complete"%', 'a completed job cannot be completed again');
select is((select count(*)::int from inventory_txns
            where product_id = '00000000-0000-0000-0000-0000000000b1' and txn_type = 'consume'),
          1, 'the string is used up once, not once per click');

-- ---------------------------------------------------------------------------
-- Strings are fixed once the job is strung (#20)
-- ---------------------------------------------------------------------------
select throws_like(
  $$ update string_jobs set main_tension = 58 where id = '00000000-0000-0000-0000-000000000f01' $$,
  '%strings on a complete string job can''t be changed%', 'a completed job''s tension cannot be changed');
select throws_like(
  $$ update string_jobs set cross_product_id = null, cross_string = 'Something else'
      where id = '00000000-0000-0000-0000-000000000f01' $$,
  '%strings on a complete string job can''t be changed%', 'a completed job''s string cannot be swapped');
select lives_ok(
  $$ update string_jobs set notes = 'customer asked for a stencil', strung_by = 'Alex', price = 32
      where id = '00000000-0000-0000-0000-000000000f01' $$,
  'notes, stringer and (unpaid) price can still be edited after completion');
select lives_ok(
  $$ update string_jobs set main_tension = 52 where id = '00000000-0000-0000-0000-000000000f02' $$,
  'an entered job''s strings can still be edited');

-- ---------------------------------------------------------------------------
-- Delivery needs payment (#20); job lines are qty 1 (#10)
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f01', 'delivered') $$,
  '%Take payment for this string job before marking it delivered%', 'an unpaid job cannot be delivered');
select throws_like(
  $$ select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":2,"unit_price":16}]'::jsonb,
                        null, '[{"method":"cash","amount":32}]'::jsonb, null) $$,
  '%qty must be 1%', 'a string job cannot be charged with qty 2');
select is((select paid_sale_id from string_jobs where id = '00000000-0000-0000-0000-000000000f01'), null,
          'the refused sale left the job unpaid');
select lives_ok(
  $$ select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":32}]'::jsonb,
                        null, '[{"method":"cash","amount":32}]'::jsonb, null) $$,
  'the job is paid with a qty 1 line');
select is(advance_string_job('00000000-0000-0000-0000-000000000f01', 'delivered'), 'delivered',
          'a paid, completed job can be delivered');
select throws_like(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f01', 'entered') $$,
  '%Cannot move a string job from "delivered" to "entered"%', 'a delivered job cannot be reopened');

-- ---------------------------------------------------------------------------
-- A paid job can't be cancelled (#2)
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f02","qty":1,"unit_price":30}]'::jsonb,
                        null, '[{"method":"cash","amount":30}]'::jsonb, null) $$,
  'a job can be paid before it is strung');
select throws_like(
  $$ select cancel_string_job('00000000-0000-0000-0000-000000000f02') $$,
  '%has been paid, so it can''t be cancelled%', 'a paid job cannot be cancelled');
select is((select status from string_jobs where id = '00000000-0000-0000-0000-000000000f02'), 'entered',
          'the paid job is still entered');

-- ---------------------------------------------------------------------------
-- A cancelled job stays cancelled (#3)
-- ---------------------------------------------------------------------------
select is(cancel_string_job('00000000-0000-0000-0000-000000000f03'), 'cancelled', 'an unpaid entered job can be cancelled');
select throws_like(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f03', 'entered') $$,
  '%Cannot move a string job from "cancelled" to "entered"%', 'a cancelled job cannot be revived');
select throws_like(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f03', 'complete') $$,
  '%Cannot move a string job from "cancelled" to "complete"%', 'a cancelled job cannot be completed');
select throws_like(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f03', 'cancelled') $$,
  '%Cannot move%', 'advance cannot be used to cancel');
select is((select committed from product_available where product_id = '00000000-0000-0000-0000-0000000000b1'),
          1, 'only the still-entered job holds string after the refused moves');

-- ---------------------------------------------------------------------------
-- One open job per active racquet (#20)
-- ---------------------------------------------------------------------------
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
      values ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 30) $$,
  '%already has an open string job%', 'a racquet with an entered job cannot get a second one');
select lives_ok(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f02', 'complete') $$,
  'the prepaid job is strung');
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
      values ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 30) $$,
  '%already has an open string job%', 'a racquet waiting for pickup cannot get a second job');
select lives_ok(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
      values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 30) $$,
  'once its job is delivered, a racquet can get a new one');
select lives_ok(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
      values ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 30) $$,
  'once its job is cancelled, a racquet can get a new one');
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
      values ('00000000-0000-0000-0000-0000000000f4', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 30) $$,
  '%has been retired%', 'a retired racquet cannot get a new job');
select has_index('public', 'string_jobs', 'uq_string_jobs_one_open_per_racket',
                 'a unique index backs up the one-open-job rule');

-- ---------------------------------------------------------------------------
-- Accounts without staff access can't move jobs
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a3');
select throws_ok(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f02', 'delivered') $$,
  '42501', null, 'a pending account cannot deliver a job');
select throws_ok(
  $$ select cancel_string_job('00000000-0000-0000-0000-000000000f02') $$,
  '42501', null, 'a pending account cannot cancel a job');
select tests.clear_authentication();
select is((select status from string_jobs where id = '00000000-0000-0000-0000-000000000f02'), 'complete',
          'the pending account changed nothing');

select * from finish();
rollback;
