-- Each sale line keeps the product's cost when it was sold (0094).
begin;
\ir helpers/setup.psql

select plan(6);

create function tests.line(p_product uuid, p_qty integer, p_price numeric)
returns jsonb language sql immutable as $$ select jsonb_build_object('product_id', p_product, 'qty', p_qty, 'unit_price', p_price) $$;
grant execute on function tests.line(uuid, integer, numeric) to authenticated;

-- A string (cost $8) sold by staff.
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
create temp table s as select record_sale(jsonb_build_array(tests.line('00000000-0000-0000-0000-0000000000b1', 2, 20)),
  null, '[{"method":"cash","amount":43.30}]'::jsonb, null) as id;
grant select on s to authenticated;
select tests.clear_authentication();

select results_eq(
  $$ select unit_cost, unit_cost_estimated from sale_lines where sale_id = (select id from s) $$,
  $$ values (8.00::numeric, false) $$,
  'a product line keeps the product''s cost when it''s sold');

-- Changing the cost later doesn't rewrite the sale.
update products set cost = 9.50 where id = '00000000-0000-0000-0000-0000000000b1';
select is((select unit_cost from sale_lines where sale_id = (select id from s)), 8.00::numeric,
          'a later cost change leaves the sold line as it was');

-- Whatever the caller sends is replaced by the product's cost.
insert into sales (id, subtotal, tax, tax_rate) values ('00000000-0000-0000-0000-0000000005b1', 20, 0, 0);
insert into sale_lines (sale_id, product_id, qty, unit_price, unit_cost, unit_cost_estimated)
values ('00000000-0000-0000-0000-0000000005b1', '00000000-0000-0000-0000-0000000000b1', 1, 20, 0.01, true);
select results_eq(
  $$ select unit_cost, unit_cost_estimated from sale_lines where sale_id = '00000000-0000-0000-0000-0000000005b1' $$,
  $$ values (9.50::numeric, false) $$,
  'a cost sent with the line is ignored');

-- No cost recorded: null, not $0.
update products set cost = null where id = '00000000-0000-0000-0000-0000000000b2';
insert into sales (id, subtotal, tax, tax_rate) values ('00000000-0000-0000-0000-0000000005b2', 250, 0, 0);
insert into sale_lines (sale_id, product_id, qty, unit_price)
values ('00000000-0000-0000-0000-0000000005b2', '00000000-0000-0000-0000-0000000000b2', 1, 250);
select is((select unit_cost from sale_lines where sale_id = '00000000-0000-0000-0000-0000000005b2'), null::numeric,
          'a product with no cost recorded gives no cost, not $0');

-- A gift card load has no cost.
insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000006b1', 'GCCOST1');
insert into sales (id, subtotal, tax, tax_rate) values ('00000000-0000-0000-0000-0000000005b3', 25, 0, 0);
insert into sale_lines (sale_id, gift_card_id, qty, unit_price)
values ('00000000-0000-0000-0000-0000000005b3', '00000000-0000-0000-0000-0000000006b1', 1, 25);
select is((select unit_cost from sale_lines where sale_id = '00000000-0000-0000-0000-0000000005b3'), null::numeric,
          'a gift card load has no cost');

-- The one-time backfill (0094) has run and is gone, so it can't mark newer
-- lines as estimated (0103).
select hasnt_function('public', 'fill_estimated_sale_line_costs', 'the one-time cost backfill is gone');

select * from finish();
rollback;
