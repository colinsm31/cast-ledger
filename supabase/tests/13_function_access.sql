-- Owner-rights (SECURITY DEFINER) functions skip row-level security, so each
-- one signed-in users can call must refuse accounts without staff access
-- (commit 2c). The first check pins the list: a new function fails it until
-- someone confirms it calls require_staff() (or only writes, which the 0041
-- trigger refuses for non-staff) and adds it here.
begin;
\ir helpers/setup.psql

select plan(13);

select is(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosecdef
      and has_function_privilege('authenticated', p.oid, 'execute')),
  array[
    -- write data: the 0041 trigger refuses non-staff writes
    'add_store_credit', 'adjust_gift_card', 'adjust_stock', 'advance_string_job',
    'cancel_string_job', 'change_paid_string_job', 'ensure_gift_card',
    -- answer only about the caller
    'is_admin', 'is_staff',
    'receive_stock', 'receive_units', 'record_refund', 'record_sale',
    'require_staff',
    -- checks is_admin() first
    'set_user_role',
    -- read-only: call require_staff()
    'string_change_quote', 'string_job_side', 'string_job_strings_price'
  ]::text[],
  'every owner-rights function signed-in users can call has been reviewed');

select is(
  (select count(*)::int from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prosecdef
      and has_function_privilege('anon', p.oid, 'execute')),
  0, 'signed-out visitors can call no owner-rights function');

insert into sales (id, subtotal, tax, tax_rate) values ('00000000-0000-0000-0000-0000000005a1', 20, 1.65, 8.25);
insert into sale_payments (sale_id, method, amount) values ('00000000-0000-0000-0000-0000000005a1', 'cash', 21.65);
select tests.create_staff('00000000-0000-0000-0000-0000000000a3', 'pending@test.local', 'pending');

-- ---------------------------------------------------------------------------
-- An account waiting for approval
-- ---------------------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a3');

select throws_ok(
  $$ select * from sale_refundable_by_method('00000000-0000-0000-0000-0000000005a1', null) $$,
  '42501', null, 'a pending account can''t read what a sale took by payment type');
select throws_ok(
  $$ select sale_refund_tax('00000000-0000-0000-0000-0000000005a1', 20, null) $$,
  '42501', null, 'a pending account can''t read a sale''s refundable tax');
select throws_ok(
  $$ select refund_method_overages('00000000-0000-0000-0000-0000000005a1', null) $$,
  '42501', null, 'a pending account can''t call the refund payment-type check');
select throws_ok(
  $$ select string_job_strings_price('00000000-0000-0000-0000-0000000000b1', null) $$,
  '42501', null, 'a pending account can''t read a string''s price');
select throws_ok(
  $$ select string_change_quote('00000000-0000-0000-0000-00000000dead', '00000000-0000-0000-0000-0000000000b1',
                                '00000000-0000-0000-0000-0000000000b1') $$,
  '42501', null, 'a pending account can''t get a string change quote');
select throws_ok(
  $$ select * from string_job_side('00000000-0000-0000-0000-0000000000b1', null, false, 'mains') $$,
  '42501', null, 'a pending account can''t call the string check');
select is(is_staff(), false, 'a pending account can still ask whether it has staff access');

-- ---------------------------------------------------------------------------
-- Approved staff: the internal helpers aren't callable directly either, but
-- the functions that use them still work.
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

select throws_ok(
  $$ select * from sale_refundable_by_method('00000000-0000-0000-0000-0000000005a1', null) $$,
  '42501', null, 'staff can''t call the internal refund helpers directly');
select is(string_job_strings_price('00000000-0000-0000-0000-0000000000b1', null), 20.00::numeric,
          'staff can get a string''s price (labor + string)');

insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Frame');
select lives_ok(
  $$ insert into string_jobs (customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b1',
             '00000000-0000-0000-0000-0000000000b1', 52, 52, 20) $$,
  'entering a job (whose trigger uses the price function) still works');

create temp table product_sale as
select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb,
                   null, '[{"method":"cash","amount":21.65}]'::jsonb, null) as id;
select lives_ok(
  $$ select record_refund((select id from product_sale),
       jsonb_build_array(jsonb_build_object('sale_line_id',
         (select id from sale_lines where sale_id = (select id from product_sale)), 'qty', 1)),
       '[{"method":"cash","amount":21.65}]'::jsonb, 'return', null) $$,
  'a refund (which uses the internal helpers) still works');
select tests.clear_authentication();

select * from finish();
rollback;
