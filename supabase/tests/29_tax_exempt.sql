-- Tax-exempt customers: only an admin can set the exemption; their sales
-- charge no tax, keep the exemption ID, refund no tax, and are reported
-- separately (Phase 2B).
begin;
\ir helpers/setup.psql

select plan(20);

-- b1 is a $20 string; tax is 8.25%. c1 is a customer; c2 will be exempt.
insert into customers (id, first_name, last_name) values
  ('00000000-0000-0000-0000-0000000000c2', 'Exempt', 'School');
create function tests.line(p_qty integer, p_price numeric) returns jsonb language sql immutable as $$
  select jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000b1', 'qty', p_qty, 'unit_price', p_price);
$$;
grant execute on function tests.line(integer, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Setting the exemption
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ update customers set tax_exempt = true where id = '00000000-0000-0000-0000-0000000000c2' $$,
  '23514', null, 'an exemption needs its ID');
select throws_ok(
  $$ update customers set tax_exempt_id = 'TX-1' where id = '00000000-0000-0000-0000-0000000000c2' $$,
  '23514', null, 'an ID without the exemption is refused');
select throws_ok(
  $$ update customers set tax_exempt = true, tax_exempt_id = ' TX-1 ' where id = '00000000-0000-0000-0000-0000000000c2' $$,
  '23514', null, 'the ID is stored trimmed');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  $$ update customers set tax_exempt = true, tax_exempt_id = 'TX-1' where id = '00000000-0000-0000-0000-0000000000c2' $$,
  '42501', 'Only an admin can change a customer''s tax exemption', 'staff can''t make a customer tax-exempt');
select throws_ok(
  $$ insert into customers (first_name, last_name, tax_exempt, tax_exempt_id) values ('New', 'Exempt', true, 'TX-9') $$,
  '42501', 'Only an admin can change a customer''s tax exemption', 'or create one that is');
select lives_ok(
  $$ update customers set phone_number = '5551234567' where id = '00000000-0000-0000-0000-0000000000c2' $$,
  'staff can still edit the rest of the customer');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok(
  $$ update customers set tax_exempt = true, tax_exempt_id = 'TX-12345' where id = '00000000-0000-0000-0000-0000000000c2' $$,
  'an admin can');

-- ---------------------------------------------------------------------------
-- Quoting and selling
-- ---------------------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
create temp table q as
  select quote_sale(jsonb_build_array(tests.line(2, 20)), '00000000-0000-0000-0000-0000000000c2') as exempt,
         quote_sale(jsonb_build_array(tests.line(2, 20)), '00000000-0000-0000-0000-0000000000c1') as taxed;
select results_eq(
  $$ select (exempt->>'tax')::numeric, (exempt->>'tax_rate')::numeric, (exempt->>'total')::numeric,
            (exempt->>'tax_exempt')::boolean, exempt->>'tax_exempt_id' from q $$,
  $$ values (0::numeric, 0::numeric, 40::numeric, true, 'TX-12345') $$,
  'an exempt customer''s quote has no tax and names the exemption');
select results_eq(
  $$ select (taxed->>'tax')::numeric, (taxed->>'tax_exempt')::boolean, taxed->>'tax_exempt_id' from q $$,
  $$ values (3.30::numeric, false, null::text) $$,
  'another customer is taxed as before');

create temp table s1 as select record_sale(jsonb_build_array(tests.line(2, 20)), '00000000-0000-0000-0000-0000000000c2',
  '[{"method":"cash","amount":40}]'::jsonb, null) as id;
select results_eq(
  $$ select tax, tax_rate, tax_exempt_id from sales where id = (select id from s1) $$,
  $$ values (0::numeric, 0::numeric, 'TX-12345') $$,
  'the sale charges no tax and keeps the exemption ID');
select throws_like(
  $$ select record_sale(jsonb_build_array(tests.line(1, 20)), '00000000-0000-0000-0000-0000000000c2',
                        '[{"method":"cash","amount":21.65}]'::jsonb, null) $$,
  'Payments ($21.65) must equal the sale total ($20.00)%', 'paying with tax is refused');

create temp table s2 as select record_sale(jsonb_build_array(tests.line(1, 20)), '00000000-0000-0000-0000-0000000000c1',
  '[{"method":"cash","amount":21.65}]'::jsonb, null) as id;
select is((select tax_exempt_id from sales where id = (select id from s2)), null, 'a taxed sale has no exemption ID');

select is(
  (quote_sale(jsonb_build_array(tests.line(1, 20)), null))->>'tax_exempt_id', null,
  'a sale with no customer is taxed');

-- Discounts still come off before the (zero) tax.
select results_eq(
  $$ select (q->>'subtotal')::numeric, (q->>'tax')::numeric
       from (select quote_sale(jsonb_build_array(tests.line(1, 20)), '00000000-0000-0000-0000-0000000000c2',
                               '{"discount": 0.1, "discount_reason": "Loyalty"}') as q) x $$,
  $$ values (18::numeric, 0::numeric) $$,
  'a discounted exempt sale is untaxed too');

-- ---------------------------------------------------------------------------
-- Later changes and refunds
-- ---------------------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
update customers set tax_exempt = false, tax_exempt_id = null where id = '00000000-0000-0000-0000-0000000000c2';
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select is((select tax_exempt_id from sales where id = (select id from s1)), 'TX-12345',
          'ending the exemption leaves past sales as recorded');
select is(
  (quote_sale(jsonb_build_array(tests.line(1, 20)), '00000000-0000-0000-0000-0000000000c2'))->>'tax', '1.65',
  'and new sales to them are taxed');

create temp table r1 as select record_refund(
  (select id from s1),
  jsonb_build_array(jsonb_build_object('sale_line_id', (select id from sale_lines where sale_id = (select id from s1)), 'qty', 1)),
  '[{"method":"cash","amount":20}]'::jsonb, 'Changed mind', null, null) as id;
select results_eq(
  $$ select subtotal, tax from refunds where id = (select id from r1) $$,
  $$ values (20::numeric, 0::numeric) $$,
  'refunding an exempt sale gives back no tax');

-- ---------------------------------------------------------------------------
-- The report
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select exempt_tickets, exempt_sales, tax from sales_summary(now() - interval '1 day', now() + interval '1 day') $$,
  $$ values (1, 40::numeric, 1.65::numeric) $$,
  'the report counts tax-exempt tickets and their sales separately');

select ok(not has_function_privilege('authenticated', 'customer_tax_exempt_id(uuid)', 'execute')
          and not has_function_privilege('authenticated', 'sale_totals(jsonb, jsonb, boolean)', 'execute'),
          'the exemption helpers are internal');
select ok(not has_function_privilege('anon', 'sales_summary(timestamptz, timestamptz)', 'execute'),
          'signed-out visitors can''t read the report');

select * from finish();
rollback;
