-- Report rows in one fixed order (0118), and an exchange's moved price (0105, 4B review 15).
begin;
\ir helpers/setup.psql

select plan(3);

-- Two products with the same name, brand and category, each with one on hand.
insert into products (id, category_id, brand, name, sell_price, cost) values
  ('00000000-0000-0000-0000-0000000000e9', '00000000-0000-0000-0000-0000000000d1', 'Same', 'Twin', 10, 5),
  ('00000000-0000-0000-0000-0000000000e8', '00000000-0000-0000-0000-0000000000d1', 'Same', 'Twin', 10, 5);
insert into inventory_txns (txn_type, product_id, qty) values
  ('receive', '00000000-0000-0000-0000-0000000000e9', 1), ('receive', '00000000-0000-0000-0000-0000000000e8', 1);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select results_eq(
  $$ select product_id from report_inventory_value() where product = 'Same Twin' $$,
  $$ values ('00000000-0000-0000-0000-0000000000e8'::uuid), ('00000000-0000-0000-0000-0000000000e9'::uuid) $$,
  'rows that tie on every shown column come back in one fixed order');

-- An exchange line that carries the list price the screen showed is refused
-- once the catalog price has moved, as at the register (0105).
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
create temp table card as
select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]',
                   '00000000-0000-0000-0000-0000000000c1', '[{"method":"credit","amount":21.65}]', null) as id;
grant select on card to authenticated;
select tests.clear_authentication();
update products set sell_price = 22 where id = '00000000-0000-0000-0000-0000000000b1';
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like(
  $$ select record_exchange((select id from card),
       (select jsonb_build_array(jsonb_build_object('sale_line_id', id, 'qty', 1)) from sale_lines
         where sale_id = (select id from card)),
       '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20,"list_price":20}]',
       '00000000-0000-0000-0000-0000000000c1', '[]', '[]', null) $$,
  '%price%', 'an exchange showing an old catalog price is refused, not saved as a price change');
select lives_ok(
  $$ select record_exchange((select id from card),
       (select jsonb_build_array(jsonb_build_object('sale_line_id', id, 'qty', 1)) from sale_lines
         where sale_id = (select id from card)),
       '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":22,"list_price":22}]',
       '00000000-0000-0000-0000-0000000000c1', '[{"method":"credit","amount":2.17}]', '[]', null) $$,
  'with the new price shown, the exchange goes through');

select * from finish();
rollback;
