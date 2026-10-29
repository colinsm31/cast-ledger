-- Amounts and quantities are real numbers (polish review #1): NaN and infinity
-- are refused by every function that takes one, and no stored number column
-- accepts NaN.
begin;
\ir helpers/setup.psql

select plan(13);

insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e2', 'GC-NAN');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- Gift cards and store credit.
select throws_like(
  $$ select adjust_gift_card('00000000-0000-0000-0000-0000000000e2', 'NaN', 'test') $$,
  '%Adjustment must be a number (got NaN)%', 'a NaN gift card adjustment is refused');
select throws_like(
  $$ select adjust_gift_card('00000000-0000-0000-0000-0000000000e2', 'Infinity', 'test') $$,
  '%Adjustment must be a number (got Infinity)%', '... and so is infinity');
select throws_like(
  $$ select add_store_credit('00000000-0000-0000-0000-0000000000c1', 'NaN', 'test') $$,
  '%Store credit amount must be a number%', 'NaN store credit is refused');
select is((select count(*)::int from gift_card_txns where gift_card_id = '00000000-0000-0000-0000-0000000000e2'), 0,
          'nothing was added to the card');

-- Stock.
select throws_like(
  $$ select receive_stock('00000000-0000-0000-0000-0000000000b1', 'NaN', null, null, null) $$,
  '%Quantity must be a number (got NaN)%', 'a NaN received quantity is refused');
select throws_like(
  $$ select receive_stock('00000000-0000-0000-0000-0000000000b1', 1, 'NaN', null, null) $$,
  '%Unit cost must be a number%', 'a NaN unit cost is refused');
select throws_like(
  $$ select adjust_stock('00000000-0000-0000-0000-0000000000b1', 'NaN', null) $$,
  '%Quantity must be a number%', 'a NaN stock adjustment is refused');
select is((select sum(qty) from inventory_txns where product_id = '00000000-0000-0000-0000-0000000000b1'),
          10::numeric, 'stock on hand is unchanged');

-- Sales: prices and payments arrive as JSON, where NaN can be sent as text.
select throws_like(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":"NaN"}]'::jsonb,
                        null, '[{"method":"cash","amount":20}]'::jsonb, null) $$,
  '%Price must be a number%', 'a NaN price on a sale is refused');
select throws_like(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb,
                        null, '[{"method":"cash","amount":"NaN"}]'::jsonb, null) $$,
  '%Payment amount must be a number%', 'a NaN payment is refused');

-- Direct table saves.
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(
  $$ update products set sell_price = 'NaN' where id = '00000000-0000-0000-0000-0000000000b1' $$,
  '23514', null, 'a NaN product price is refused');
select throws_ok(
  $$ update settings set stringing_labor = 'NaN' where id $$,
  '23514', null, 'a NaN setting is refused');

select tests.clear_authentication();
select is((select count(*)::int from pg_constraint
            where conname like 'ck\_%\_number' and connamespace = 'public'::regnamespace), 21,
          'all 21 stored number columns refuse NaN');

select * from finish();
rollback;
