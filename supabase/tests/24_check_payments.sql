-- Checks as a payment type: off until the shop turns them on, always with a
-- check number, refundable by check, and counted in the sales report
-- (Phase 2A).
begin;
\ir helpers/setup.psql

select plan(22);

-- Settings are admin-only; the tests switch checks on and off through this.
create function tests.set_accept_checks(p_on boolean) returns void
language sql security definer set search_path = public, pg_temp
as $$ update settings set accept_checks = p_on where id; $$;
grant usage on schema tests to authenticated;
grant execute on function tests.set_accept_checks(boolean) to authenticated;

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- One $20 string (taxed at 8.25%: $21.65).
create temp table one_string as
select '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb as lines;
grant select on one_string to authenticated;

-- ---------------------------------------------------------------------------
-- Off by default
-- ---------------------------------------------------------------------------
select is((select accept_checks from settings where id), false, 'checks are off until the shop turns them on');
select throws_like(
  $$ select record_sale((select lines from one_string), null,
                        '[{"method":"check","amount":21.65,"check_number":"1042"}]'::jsonb, null) $$,
  '%doesn''t take checks%', 'a check is refused while checks are off');

select tests.set_accept_checks(true);

-- ---------------------------------------------------------------------------
-- Check numbers
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select record_sale((select lines from one_string), null, '[{"method":"check","amount":21.65}]'::jsonb, null) $$,
  '%needs its check number%', 'a check needs its number');
select throws_like(
  $$ select record_sale((select lines from one_string), null,
                        '[{"method":"check","amount":21.65,"check_number":"10-42"}]'::jsonb, null) $$,
  '%digits only%', 'a check number is digits only');
select throws_like(
  $$ select record_sale((select lines from one_string), null,
                        '[{"method":"check","amount":21.65,"check_number":"12345678901"}]'::jsonb, null) $$,
  '%up to 10%', 'a check number is at most 10 digits');
select throws_like(
  $$ select record_sale((select lines from one_string), null,
                        '[{"method":"check","amount":30,"check_number":"1042"}]'::jsonb, null) $$,
  '%must equal the sale total%', 'a check for more than is owed is refused (no change is given on a check)');

-- ---------------------------------------------------------------------------
-- Paying by check
-- ---------------------------------------------------------------------------
create temp table check_sale as
select record_sale((select lines from one_string), '00000000-0000-0000-0000-0000000000c1',
                   '[{"method":"check","amount":21.65,"check_number":" 1042 "}]'::jsonb, null) as id;
grant select on check_sale to authenticated;
select results_eq(
  $$ select method, amount, check_number from sale_payments where sale_id = (select id from check_sale) $$,
  $$ values ('check'::text, 21.65::numeric, '1042'::text) $$,
  'the check is saved with its trimmed number');
select is((select payment_method from sales where id = (select id from check_sale)), 'check',
          'the sale''s payment type is check');

create temp table split_sale as
select record_sale((select lines from one_string), null,
                   '[{"method":"check","amount":20,"check_number":"77"},{"method":"cash","amount":1.65}]'::jsonb, null) as id;
grant select on split_sale to authenticated;
select is((select payment_method from sales where id = (select id from split_sale)), 'split',
          'a check with cash is a split payment');
select is((select check_number from sale_payments where sale_id = (select id from split_sale) and method = 'cash'), null,
          'other payment types have no check number');

-- ---------------------------------------------------------------------------
-- Refunds
-- ---------------------------------------------------------------------------
create temp table check_line as
select id from sale_lines where sale_id = (select id from check_sale);
grant select on check_line to authenticated;

select throws_like(
  $$ select record_refund((select id from check_sale), jsonb_build_array(jsonb_build_object('sale_line_id', (select id from check_line), 'qty', 1)),
                          '[{"method":"cash","amount":21.65}]'::jsonb, null, null, null) $$,
  '%more to cash than the sale took that way%', 'cash back for a check sale is a payment-type change, so it needs a reason');
select throws_like(
  $$ select record_refund((select id from check_sale), jsonb_build_array(jsonb_build_object('sale_line_id', (select id from check_line), 'qty', 1)),
                          '[{"method":"check","amount":21.65}]'::jsonb, null, null, null) $$,
  '%needs its check number%', 'a refund check needs its number');

-- Checks turned off after the sale: a check sale can still be refunded by check.
select tests.set_accept_checks(false);
create temp table check_refund as
select record_refund((select id from check_sale), jsonb_build_array(jsonb_build_object('sale_line_id', (select id from check_line), 'qty', 1)),
                     '[{"method":"check","amount":21.65,"check_number":"501"}]'::jsonb, null, null, null) as id;
grant select on check_refund to authenticated;
select results_eq(
  $$ select method, amount, check_number from refund_payments where refund_id = (select id from check_refund) $$,
  $$ values ('check'::text, 21.65::numeric, '501'::text) $$,
  'a check sale is refunded by check, even after checks were turned off');
select is((select method_change_reason from refunds where id = (select id from check_refund)), null,
          '... with no payment-type change');

-- A sale not paid by check can't be refunded by check while checks are off.
create temp table cash_sale as
select record_sale((select lines from one_string), null, '[{"method":"cash","amount":21.65}]'::jsonb, null) as id;
grant select on cash_sale to authenticated;
select throws_like(
  $$ select record_refund((select id from cash_sale),
                          (select jsonb_build_array(jsonb_build_object('sale_line_id', id, 'qty', 1)) from sale_lines where sale_id = (select id from cash_sale)),
                          '[{"method":"check","amount":21.65,"check_number":"502"}]'::jsonb, null, null, 'Customer asked') $$,
  '%doesn''t take checks%', 'a cash sale can''t be refunded by check while checks are off');

select tests.set_accept_checks(true);
select lives_ok(
  $$ select record_refund((select id from cash_sale),
                          (select jsonb_build_array(jsonb_build_object('sale_line_id', id, 'qty', 1)) from sale_lines where sale_id = (select id from cash_sale)),
                          '[{"method":"check","amount":21.65,"check_number":"502"}]'::jsonb, null, null, 'Customer asked') $$,
  'with checks on, it can, as a payment-type change with a reason');

-- ---------------------------------------------------------------------------
-- The report
-- ---------------------------------------------------------------------------
create temp table report as
select * from sales_summary(now() - interval '1 hour', now() + interval '1 hour');
select is((select check_amt from report), -1.65::numeric,
          'checks: $21.65 + $20 taken, $21.65 + $21.65 refunded');
select is((select card + cash + check_amt + store_credit + gift_card from report), (select net from report),
          'the tender totals still add up to net receipts');

-- ---------------------------------------------------------------------------
-- The tables and the helper
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
select throws_ok(
  $$ update sale_payments set check_number = null where sale_id = (select id from check_sale) $$,
  '23514', null, 'a saved check always has its number');
select throws_ok(
  $$ update sale_payments set check_number = '9' where sale_id = (select id from split_sale) and method = 'cash' $$,
  '23514', null, 'only checks have a number');
select ok(not has_function_privilege('authenticated', 'require_check_number(text)', 'execute'),
          'the check number rule is internal');
select ok(not has_function_privilege('anon', 'record_sale(jsonb, uuid, jsonb, text)', 'execute'),
          'signed-out visitors still can''t record a sale');

select * from finish();
rollback;
