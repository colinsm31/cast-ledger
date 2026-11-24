-- An exchange whose credit came from more than one payment type is split (0092).
begin;
\ir helpers/setup.psql

select plan(3);

create function tests.line(p_product uuid, p_qty integer, p_price numeric)
returns jsonb language sql immutable as $$ select jsonb_build_object('product_id', p_product, 'qty', p_qty, 'unit_price', p_price) $$;
create function tests.return_of(p_sale uuid, p_product uuid, p_qty integer)
returns jsonb language sql stable as $$
  select jsonb_build_array(jsonb_build_object('sale_line_id', id, 'qty', p_qty)) from sale_lines where sale_id = p_sale and product_id = p_product
$$;
grant execute on function tests.line(uuid, integer, numeric), tests.return_of(uuid, uuid, integer) to authenticated;

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
-- A string paid half in cash, half by card, exchanged for another.
create temp table s as select record_sale(jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 1, 20)),
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":10},{"method":"credit","amount":11.65}]'::jsonb, null) as id;
grant select on s to authenticated;
create temp table e as select record_exchange((select id from s),
  tests.return_of((select id from s), '00000000-0000-0000-0000-0000000000b1', 1),
  jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 1, 20)),
  '00000000-0000-0000-0000-0000000000c1', '[]'::jsonb, '[]'::jsonb, null) as x;
grant select on e to authenticated;

select results_eq(
  $$ select method, source_method, amount from sale_payments
      where sale_id = ((select x from e)->>'sale_id')::uuid order by source_method $$,
  $$ values ('exchange'::text, 'cash'::text, 10.00::numeric), ('exchange'::text, 'credit'::text, 11.65::numeric) $$,
  'the credit keeps the two payment types it came from');
select is((select payment_method from sales where id = ((select x from e)->>'sale_id')::uuid), 'split',
          'so the new sale reads as split, not paid one way');

-- One payment type: still the exchange alone.
create temp table s2 as select record_sale(jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 1, 20)),
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":21.65}]'::jsonb, null) as id;
grant select on s2 to authenticated;
create temp table e2 as select record_exchange((select id from s2),
  tests.return_of((select id from s2), '00000000-0000-0000-0000-0000000000b1', 1),
  jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 1, 20)),
  '00000000-0000-0000-0000-0000000000c1', '[]'::jsonb, '[]'::jsonb, null) as x;
grant select on e2 to authenticated;
select is((select payment_method from sales where id = ((select x from e2)->>'sale_id')::uuid), 'exchange',
          'credit from one payment type is still paid by the exchange');

select * from finish();
rollback;
