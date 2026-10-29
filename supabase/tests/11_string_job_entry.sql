-- Entering a string job: specific catalog strings with every attribute and a
-- tension, details copied from the catalog, and availability respected when
-- "block overselling" is on (code review #19 for strings, #20).
begin;
\ir helpers/setup.psql

select plan(23);

-- More strings (real Strings category):
--   b4  Black 17, 1 on hand (the last unit)
--   b5  no gauge set in the catalog
--   b6  inactive
--   b7  Blue 17 with an extra non-attribute field, none on hand
insert into products (id, category_id, brand, name, sell_price, attributes, is_active)
select v.id, c.id, 'TestBrand', v.name, 18, v.attrs::jsonb, v.active
  from categories c,
       (values
         ('00000000-0000-0000-0000-0000000000b4'::uuid, 'Last Unit',  '{"color":"Black","gauge":"17"}', true),
         ('00000000-0000-0000-0000-0000000000b5'::uuid, 'No Gauge',   '{"color":"Red"}', true),
         ('00000000-0000-0000-0000-0000000000b6'::uuid, 'Retired',    '{"color":"White","gauge":"16"}', false),
         ('00000000-0000-0000-0000-0000000000b7'::uuid, 'Out Of Stock', '{"color":"Blue","gauge":"17","restringing_price":"40"}', true)
       ) as v(id, name, attrs, active)
 where c.name = 'Strings';
insert into inventory_txns (txn_type, product_id, qty) values ('receive', '00000000-0000-0000-0000-0000000000b4', 1);

insert into customers (id, first_name, last_name) values ('00000000-0000-0000-0000-0000000000c2', 'Sam', 'Tester');
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Frame 1'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'Frame 2'),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000c1', 'Frame 3'),
  ('00000000-0000-0000-0000-0000000000f4', '00000000-0000-0000-0000-0000000000c1', 'Frame 4'),
  ('00000000-0000-0000-0000-0000000000f5', '00000000-0000-0000-0000-0000000000c2', 'Sam''s Frame');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------------
-- Default string attributes
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select a.name from attribute_defs a join categories c on c.id = a.category_id
      where c.name = 'Strings' order by a.name $$,
  $$ values ('color'::text), ('gauge'::text) $$,
  'strings have two attributes by default: color and gauge');

-- ---------------------------------------------------------------------------
-- Every part of the string and a tension is required
-- ---------------------------------------------------------------------------
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_tension, cross_tension, price)
     values ('00000000-0000-0000-0000-0000000000f1', 52, 52, 30) $$,
  '%Choose the mains and crosses strings%', 'a job needs catalog strings');
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_product_id, main_tension, cross_tension, price)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 30) $$,
  '%Choose the mains and crosses strings%', 'a job needs a crosses string too');
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, price)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b1',
             '00000000-0000-0000-0000-0000000000b1', 52, 30) $$,
  '%Enter the mains and crosses tension%', 'a job needs both tensions');
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b2',
             '00000000-0000-0000-0000-0000000000b2', 52, 52, 30) $$,
  '%isn''t a string%', 'a product that isn''t a string is refused');
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b6',
             '00000000-0000-0000-0000-0000000000b6', 52, 52, 30) $$,
  '%no longer active%', 'an inactive string is refused');
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b5',
             '00000000-0000-0000-0000-0000000000b5', 52, 52, 30) $$,
  '%has no gauge set in the catalog%', 'a string missing a defined attribute is refused');

-- ---------------------------------------------------------------------------
-- The job's details come from the catalog string
-- ---------------------------------------------------------------------------
insert into string_jobs (id, customer_racket_id, main_product_id, main_brand, main_string, main_specs,
                         cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', 'Wrong', 'Wrong String', '{"color":"Pink"}',
        '00000000-0000-0000-0000-0000000000b4', 55, 53, 38);
select results_eq(
  $$ select main_brand, main_string, main_specs, cross_brand, cross_string, cross_specs
       from string_jobs where id = '00000000-0000-0000-0000-000000000f01' $$,
  $$ values ('TestBrand'::text, 'Test String 16'::text, '{"color":"Natural","gauge":"16"}'::jsonb,
             'TestBrand'::text, 'Last Unit'::text, '{"color":"Black","gauge":"17"}'::jsonb) $$,
  'a hybrid job stores each string''s brand, name, color and gauge from the catalog, whatever the screen sent');

-- ---------------------------------------------------------------------------
-- Availability with "block overselling" off (the fixture default)
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
     values ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000f2',
             '00000000-0000-0000-0000-0000000000b7', '00000000-0000-0000-0000-0000000000b7', 52, 52, 30) $$,
  'with blocking off, a string with none available can still be used');
select is((select main_specs from string_jobs where id = '00000000-0000-0000-0000-000000000f02'),
          '{"color":"Blue","gauge":"17"}'::jsonb,
          'only string attributes are copied, not other catalog fields');
select is((select available from product_available where product_id = '00000000-0000-0000-0000-0000000000b7'),
          -1::numeric, 'and its available count goes below zero');

-- ---------------------------------------------------------------------------
-- Availability with "block overselling" on
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
update settings set block_oversell = true where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

select is((select available from product_available where product_id = '00000000-0000-0000-0000-0000000000b4'),
          0::numeric, 'the last unit of b4 is set aside for job 1');
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
     values ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000b4',
             '00000000-0000-0000-0000-0000000000b4', 52, 52, 30) $$,
  '%Last Unit (Black 17) has none available%', 'with blocking on, a string with none available is refused');
select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
     values ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000b1',
             '00000000-0000-0000-0000-0000000000b4', 52, 52, 30) $$,
  '%has none available%', 'the crosses string is checked as well');
select lives_ok(
  $$ update string_jobs set main_tension = 56, cross_tension = 54
      where id = '00000000-0000-0000-0000-000000000f01' $$,
  'a job keeping its own last unit can still be edited');
select lives_ok(
  $$ update string_jobs set main_product_id = '00000000-0000-0000-0000-0000000000b4'
      where id = '00000000-0000-0000-0000-000000000f01' $$,
  'a job can move a string it already holds from crosses to mains');
select throws_like(
  $$ update string_jobs set main_product_id = '00000000-0000-0000-0000-0000000000b4',
                            cross_product_id = '00000000-0000-0000-0000-0000000000b4'
      where id = '00000000-0000-0000-0000-000000000f02' $$,
  '%none available%', 'a job can''t change to a string another job holds the last unit of');
select lives_ok(
  $$ update string_jobs set main_product_id = '00000000-0000-0000-0000-0000000000b1',
                            cross_product_id = '00000000-0000-0000-0000-0000000000b1'
      where id = '00000000-0000-0000-0000-000000000f02' $$,
  'a job can change to a string that has some available');
select results_eq(
  $$ select product_id, committed from product_available
      where product_id in ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b7')
      order by product_id $$,
  $$ values ('00000000-0000-0000-0000-0000000000b1'::uuid, 1), ('00000000-0000-0000-0000-0000000000b7'::uuid, 0) $$,
  'changing strings releases the old string and sets the new one aside');
-- A job needs a stringer before it's complete (0051).
update string_jobs set strung_by = 'Test Stringer' where id = '00000000-0000-0000-0000-000000000f01';
select lives_ok(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f01', 'complete') $$,
  'completing a job is never blocked by availability');

-- ---------------------------------------------------------------------------
-- One sale can pay for two customers' jobs (a family ticket)
-- ---------------------------------------------------------------------------
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f05', '00000000-0000-0000-0000-0000000000f5',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 50, 50, 30);
create temp table family_sale as
select record_sale(
  '[{"string_job_id":"00000000-0000-0000-0000-000000000f02","qty":1,"unit_price":30},
    {"string_job_id":"00000000-0000-0000-0000-000000000f05","qty":1,"unit_price":30}]'::jsonb,
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":60}]'::jsonb, null) as id;
select results_eq(
  $$ select id, status, paid_sale_id from string_jobs
      where id in ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-000000000f05') order by id $$,
  $$ select j, 'entered'::text, (select id from family_sale)
       from unnest(array['00000000-0000-0000-0000-000000000f02'::uuid, '00000000-0000-0000-0000-000000000f05'::uuid]) j $$,
  'one ticket pays for Pat''s and Sam''s jobs; both stay entered and point to that sale');

-- ---------------------------------------------------------------------------
-- Who the rules apply to
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
select lives_ok(
  $$ insert into string_jobs (customer_racket_id, price) values ('00000000-0000-0000-0000-0000000000f4', 30) $$,
  'writes with no signed-in user (migrations, maintenance) aren''t checked');
select tests.create_staff('00000000-0000-0000-0000-0000000000a3', 'pending@test.local', 'pending');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a3');
select throws_ok(
  $$ select * from string_job_side('00000000-0000-0000-0000-0000000000b1', null, false, 'mains') $$,
  '42501', null, 'an account without staff access can''t call the string check directly');
select tests.clear_authentication();

select * from finish();
rollback;
