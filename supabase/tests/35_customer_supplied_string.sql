-- The customer brings their own string (Phase 3A).
begin;
\ir helpers/setup.psql

select plan(16);

update settings set stringing_labor = 18 where id;

insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Frame 1'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'Frame 2'),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000c1', 'Frame 3'),
  ('00000000-0000-0000-0000-0000000000f4', '00000000-0000-0000-0000-0000000000c1', 'Frame 4');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------------
-- Both sides the customer's: labor only, no stock
-- ---------------------------------------------------------------------------
insert into string_jobs (id, customer_racket_id, main_customer_supplied, main_brand, main_string, main_product_id,
                         cross_customer_supplied, cross_brand, cross_string, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        true, ' Luxilon ', ' ALU Power 125 ', null, true, 'Luxilon', 'ALU Power 125', 52, 50, 18);

select results_eq(
  $$ select main_brand, main_string, main_specs, main_product_id, strings_price
       from string_jobs where id = '00000000-0000-0000-0000-000000000f01' $$,
  $$ values ('Luxilon'::text, 'ALU Power 125'::text, '{}'::jsonb, null::uuid, 18.00::numeric) $$,
  'the customer''s string is typed in, tidied, and only labor is priced');
select is((select count(*)::int from string_committed), 0, 'no shop string is set aside for it');

-- ---------------------------------------------------------------------------
-- A hybrid: the customer's mains, the shop's crosses
-- ---------------------------------------------------------------------------
insert into string_jobs (id, customer_racket_id, main_customer_supplied, main_string,
                         cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000f2',
        true, 'Own poly', '00000000-0000-0000-0000-0000000000b1', 55, 53, 38);
select results_eq(
  $$ select main_brand, main_string, cross_string, strings_price
       from string_jobs where id = '00000000-0000-0000-0000-000000000f02' $$,
  $$ values (null::text, 'Own poly'::text, 'Test String 16'::text, 38.00::numeric) $$,
  'a hybrid prices labor plus the shop''s string only');
select results_eq($$ select product_id, committed from string_committed $$,
                  $$ values ('00000000-0000-0000-0000-0000000000b1'::uuid, 1) $$,
                  'and sets aside just the shop''s string');

update string_jobs set strung_by = 'Alex' where id = '00000000-0000-0000-0000-000000000f02';
select advance_string_job('00000000-0000-0000-0000-000000000f02', 'complete');
select results_eq(
  $$ select product_id, sum(qty)::int from inventory_txns where txn_type = 'consume' group by product_id $$,
  $$ values ('00000000-0000-0000-0000-0000000000b1'::uuid, -1) $$,
  'completing it uses up one shop string and nothing for the customer''s');

-- ---------------------------------------------------------------------------
-- What a customer side needs
-- ---------------------------------------------------------------------------
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_customer_supplied, main_string, cross_customer_supplied,
                              cross_string, main_tension, cross_tension)
     values ('00000000-0000-0000-0000-0000000000f3', true, '  ', true, 'Gut', 52, 52) $$,
  'Enter the customer''s mains string', 'the customer''s string needs a name');
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_customer_supplied, main_string, cross_customer_supplied,
                              cross_string, main_tension, cross_tension)
     values ('00000000-0000-0000-0000-0000000000f3', true, 'Gut', true, repeat('x', 81), 52, 52) $$,
  'The customer''s crosses string: use at most 80 characters%', 'of at most 80 characters');
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_customer_supplied, main_string, main_product_id,
                              cross_product_id, main_tension, cross_tension)
     values ('00000000-0000-0000-0000-0000000000f3', true, 'Gut', '00000000-0000-0000-0000-0000000000b1',
             '00000000-0000-0000-0000-0000000000b1', 52, 52) $$,
  'The mains are the customer''s own string, so they can''t be a catalog string too',
  'a customer side can''t also be a catalog string');
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_customer_supplied, main_string, main_tension, cross_tension)
     values ('00000000-0000-0000-0000-0000000000f3', true, 'Gut', 52, 52) $$,
  'Choose the mains and crosses strings from the catalog', 'the shop''s side still needs a catalog string');
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_customer_supplied, main_string, cross_customer_supplied,
                              cross_string, main_tension)
     values ('00000000-0000-0000-0000-0000000000f3', true, 'Gut', true, 'Gut', 52) $$,
  'Enter the mains and crosses tension', 'and both tensions are still needed');

-- ---------------------------------------------------------------------------
-- Switching sides while it waits, but not once paid
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ update string_jobs set cross_customer_supplied = false, cross_product_id = '00000000-0000-0000-0000-0000000000b1'
      where id = '00000000-0000-0000-0000-000000000f01' $$,
  'an unpaid waiting job can switch a side to the shop''s string');
select results_eq(
  $$ select cross_string, strings_price from string_jobs where id = '00000000-0000-0000-0000-000000000f01' $$,
  $$ values ('Test String 16'::text, 38.00::numeric) $$, 'and is priced for it');

select lives_ok(
  $$ select record_sale(jsonb_build_array(jsonb_build_object('string_job_id', '00000000-0000-0000-0000-000000000f01',
                                                             'qty', 1, 'unit_price', 18)),
                        '00000000-0000-0000-0000-0000000000c1',
                        jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', 18)), null) $$,
  'the job is paid');
select throws_like(
  $$ update string_jobs set main_customer_supplied = false, main_product_id = '00000000-0000-0000-0000-0000000000b1'
      where id = '00000000-0000-0000-0000-000000000f01' $$,
  'This job is paid, so whose string it uses can''t change', 'a paid job keeps whose string each side is');
select lives_ok(
  $$ update string_jobs set main_string = 'ALU Power 125 Silver' where id = '00000000-0000-0000-0000-000000000f01' $$,
  'but the customer''s string name can be corrected');

-- Once strung, nothing about the strings changes.
select throws_like(
  $$ update string_jobs set main_customer_supplied = false where id = '00000000-0000-0000-0000-000000000f02' $$,
  'The strings on a complete string job can''t be changed', 'a strung job''s sides are fixed');

select * from finish();
rollback;
