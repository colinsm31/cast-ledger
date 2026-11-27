-- Inventory value at cost (0097).
begin;
\ir helpers/setup.psql

select plan(4);

-- The fixtures have 10 strings (cost $8, price $20). Add racquet frames (cost
-- $150, price $250): 2 in stock, 1 in the demo rack, 1 lent out, 1 sold; a
-- grip with no cost, 3 on hand; and an oversold overgrip.
insert into product_units (product_id, barcode, status, customer_id) values
  ('00000000-0000-0000-0000-0000000000b2', 'INV-1', 'in_stock', null),
  ('00000000-0000-0000-0000-0000000000b2', 'INV-2', 'in_stock', null),
  ('00000000-0000-0000-0000-0000000000b2', 'INV-3', 'demo', null),
  ('00000000-0000-0000-0000-0000000000b2', 'INV-4', 'assigned', '00000000-0000-0000-0000-0000000000c1'),
  ('00000000-0000-0000-0000-0000000000b2', 'INV-5', 'sold', '00000000-0000-0000-0000-0000000000c1');
insert into products (id, category_id, brand, name, sell_price, cost) values
  ('00000000-0000-0000-0000-0000000000b4', '00000000-0000-0000-0000-0000000000d1', null, 'Grip', 9.00, null),
  ('00000000-0000-0000-0000-0000000000b5', '00000000-0000-0000-0000-0000000000d1', 'Zeta', 'Overgrip', 4.00, 1.50),
  ('00000000-0000-0000-0000-0000000000b6', '00000000-0000-0000-0000-0000000000d1', 'Zeta', 'Empty', 4.00, 1.50);
insert into inventory_txns (txn_type, product_id, qty) values
  ('receive', '00000000-0000-0000-0000-0000000000b4', 3),
  ('adjust',  '00000000-0000-0000-0000-0000000000b5', -2);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select * from report_inventory_value() $$, '42501', 'Only an admin can see reports',
                 'staff can''t see what the stock is worth');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select results_eq(
  $$ select product, on_hand, value_at_cost, retail_value, demo_frames, demo_value_at_cost
       from report_inventory_value()
      where product_id in ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b2')
      order by product $$,
  $$ values ('TestBrand Test Racquet 100'::text, 2::numeric, 300.00::numeric, 500.00::numeric, 2, 300.00::numeric),
            ('TestBrand Test String 16', 10, 80.00, 200.00, 0, null) $$,
  'stock at cost and retail; demo frames (in the rack or lent) apart, sold frames not counted');

select results_eq(
  $$ select product, brand, on_hand, value_at_cost, retail_value
       from report_inventory_value()
      where product_id in ('00000000-0000-0000-0000-0000000000b4', '00000000-0000-0000-0000-0000000000b5')
      order by product $$,
  $$ values ('Grip'::text, null::text, 3::numeric, null::numeric, 27.00::numeric),
            ('Zeta Overgrip', 'Zeta', -2, 0.00, 0.00) $$,
  'no cost gives no value (not $0); oversold stock shows below zero but is worth nothing');

select is((select count(*)::int from report_inventory_value() where product_id = '00000000-0000-0000-0000-0000000000b6'), 0,
          'a product with nothing on hand is left out');

select * from finish();
rollback;
