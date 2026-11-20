-- String job numbers and scanning a job's tag (Phase 3A).
begin;
\ir helpers/setup.psql

select plan(9);

insert into customer_rackets (id, customer_id, model, barcode) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Frame 1', 'TAG-1'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'Frame 2', null);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 50, 30),
       ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000f2',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 50, 30);

create temp table n as
  select (select job_number from string_jobs where id = '00000000-0000-0000-0000-000000000f01') as first_no,
         (select job_number from string_jobs where id = '00000000-0000-0000-0000-000000000f02') as second_no;
grant select on n to authenticated;

select ok((select first_no >= 1001 and second_no = first_no + 1 from n), 'each job gets the next number, from 1001');

select throws_like(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, job_number)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b1',
             '00000000-0000-0000-0000-0000000000b1', 52, 50, 5) $$,
  '%job_number%', 'a number can''t be chosen');
select throws_like(
  $$ update string_jobs set job_number = 5 where id = '00000000-0000-0000-0000-000000000f01' $$,
  '%job_number%', 'or changed');

-- ---------------------------------------------------------------------------
-- Scanning the tag
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select kind, code, id, customer_id, open_job_id from resolve_barcode('J' || (select second_no from n)) $$,
  $$ values ('job'::text, 'J' || (select second_no from n), '00000000-0000-0000-0000-000000000f02'::uuid,
             '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-000000000f02'::uuid) $$,
  'a job tag finds the job and its customer');
select is((select kind from resolve_barcode(' j' || (select first_no from n) || ' ')), 'job',
          'in either case, with stray spaces');
select is((select kind from resolve_barcode('J999999999')), 'none', 'an unknown job number finds nothing');
select is((select kind from resolve_barcode('TAG-1')), 'racket', 'racquet tags still resolve as before');

-- A delivered job's tag still opens it.
update string_jobs set strung_by = 'Alex' where id = '00000000-0000-0000-0000-000000000f01';
select advance_string_job('00000000-0000-0000-0000-000000000f01', 'complete');
select is((select id from resolve_barcode('J' || (select first_no from n))), '00000000-0000-0000-0000-000000000f01'::uuid,
          'a finished job''s tag still finds it');

-- Any existing barcode that looks like a job number wins.
select tests.clear_authentication();
update customer_rackets set barcode = 'J' || (select first_no from n) where id = '00000000-0000-0000-0000-0000000000f2';
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select is((select kind from resolve_barcode('J' || (select first_no from n))), 'racket',
          'a racquet tag with the same text is found first');

select * from finish();
rollback;
