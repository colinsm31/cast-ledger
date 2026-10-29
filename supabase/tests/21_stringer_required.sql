-- A string job needs a stringer to be marked complete (polish review #7).
begin;
\ir helpers/setup.psql

select plan(6);

insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Stringer Frame');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 55, 53, 30);

select throws_like(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f01', 'complete') $$,
  '%Record who strung it before marking it complete%', 'a job with no stringer can''t be completed');

update string_jobs set strung_by = '   ' where id = '00000000-0000-0000-0000-000000000f01';
select throws_like(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f01', 'complete') $$,
  '%Record who strung it%', '... nor with a blank one');
select is((select status from string_jobs where id = '00000000-0000-0000-0000-000000000f01'), 'entered',
          'the job is still entered');
select is((select count(*)::int from inventory_txns where txn_type = 'consume'), 0,
          'no string was used up');

update string_jobs set strung_by = 'Alex' where id = '00000000-0000-0000-0000-000000000f01';
select is(advance_string_job('00000000-0000-0000-0000-000000000f01', 'complete'), 'complete',
          'with a stringer it can be completed');

select tests.clear_authentication();
select ok(not has_function_privilege('anon', 'advance_string_job(uuid, text)', 'execute'),
          'signed-out visitors still can''t call it');

select * from finish();
rollback;
