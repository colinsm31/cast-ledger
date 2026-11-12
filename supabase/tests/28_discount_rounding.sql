-- A dollar ticket discount is shared by price, each share rounded to the
-- cent: an exact half cent rounds up (0057), the same as the register.
begin;
\ir helpers/setup.psql

select plan(4);

create function tests.line(p_qty integer, p_price numeric) returns jsonb language sql immutable as $$
  select jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000b1', 'qty', p_qty, 'unit_price', p_price);
$$;
grant execute on function tests.line(integer, numeric) to authenticated;

-- Two items at $82.11, $7.77 off the ticket: each share is exactly $3.885.
select results_eq(
  $$ select (t->'lines'->0->>'ticket_discount_each')::numeric, (t->'lines'->0->>'unit_price')::numeric,
            (t->>'discount_total')::numeric
       from (select sale_totals(jsonb_build_array(tests.line(2, 82.11)), '{"discount": 7.77}') as t) x $$,
  $$ values (3.89::numeric, 78.22::numeric, 7.78::numeric) $$,
  'an exact half-cent share rounds up');

-- Shares that aren't a half cent round to the nearest cent as before.
select results_eq(
  $$ select (t->'lines'->0->>'unit_price')::numeric, (t->>'discount_total')::numeric
       from (select sale_totals(jsonb_build_array(tests.line(3, 20)), '{"discount": 5}') as t) x $$,
  $$ values (18.33::numeric, 5.01::numeric) $$,
  '$5 off three $20 items still takes $1.67 off each');

select results_eq(
  $$ select array_agg((l->>'unit_price')::numeric order by n)
       from jsonb_array_elements(sale_totals(jsonb_build_array(tests.line(1, 10), tests.line(1, 30)), '{"discount": 4}')->'lines')
            with ordinality x(l, n) $$,
  $$ values (array[9.00, 27.00]::numeric[]) $$,
  'shares follow each item''s price');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select is(
  (quote_sale(jsonb_build_array(tests.line(2, 82.11)), null, '{"discount": 7.77, "discount_reason": "Loyalty"}'))->>'subtotal',
  '156.44', 'the quote charges the rounded shares');

select * from finish();
rollback;
