-- record_sale: lines, tax, split tender, gift cards, store credit, serialized
-- units, oversell, and staff attribution.
begin;
\ir helpers/setup.psql

select plan(36);

-- Fixtures used only here: a gift card with $50 on it, $25 store credit, two
-- racquet units, and a string job.
insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e1', 'GC-TEST-1');
insert into gift_card_txns (gift_card_id, amount, reason) values ('00000000-0000-0000-0000-0000000000e1', 50, 'load');
insert into store_credit_txns (customer_id, amount, reason) values ('00000000-0000-0000-0000-0000000000c1', 25, 'fixture');
insert into customer_rackets (id, customer_id, brand, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'TestBrand', 'Old Frame');
insert into string_jobs (id, customer_racket_id, main_product_id, main_tension, price) values
  ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
   '00000000-0000-0000-0000-0000000000b1', 55, 30);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

select is(
  (select receive_units('00000000-0000-0000-0000-0000000000b2', '["RQ-UNIT-1", null]'::jsonb)),
  2, 'receive_units creates one unit per element (barcode optional)');

-- ---------------------------------------------------------------------------
-- Plain cash sale: 2 strings @ $20, 8.25% tax.
-- ---------------------------------------------------------------------------
create temp table cash_sale as
select record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":2,"unit_price":20}]'::jsonb,
  '00000000-0000-0000-0000-0000000000c1',
  '[{"method":"cash","amount":43.30}]'::jsonb,
  'first sale') as id;

select results_eq(
  $$ select subtotal, tax, tax_rate, payment_method, customer_id, note
       from sales where id = (select id from cash_sale) $$,
  $$ values (40.00::numeric(12,2), 3.30::numeric(12,2), 8.250::numeric(6,3), 'cash'::text,
             '00000000-0000-0000-0000-0000000000c1'::uuid, 'first sale'::text) $$,
  'sale stores subtotal, tax at the shop rate, the rate itself, method, customer and note');

select is((select on_hand from product_stock where product_id = '00000000-0000-0000-0000-0000000000b1'),
          8::numeric, 'selling 2 strings leaves 8 on hand');
select is((select user_id from sales where id = (select id from cash_sale)),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'sale records the staff member who rang it');
select is((select user_id from inventory_txns where sale_id = (select id from cash_sale) and txn_type = 'sell'),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'sell stock entry records the staff member');
select is((select count(*)::int from sale_payments where sale_id = (select id from cash_sale)),
          1, 'one payment row for a single-tender sale');

select throws_like(
  $$ select record_sale(
       '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb,
       null, '[{"method":"cash","amount":20}]'::jsonb, null) $$,
  '%must equal the sale total%',
  'payments that do not cover subtotal + tax are rejected');

select throws_like(
  $$ select record_sale('[]'::jsonb, null, '[]'::jsonb, null) $$,
  '%at least one line%', 'a sale needs at least one line');

select throws_like(
  $$ select record_sale(
       '[{"product_id":"00000000-0000-0000-0000-0000000000b1","string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":20}]'::jsonb,
       null, '[]'::jsonb, null) $$,
  '%exactly one of product, string job, or gift card%',
  'a line must reference exactly one thing');

select throws_like(
  $$ select record_sale(
       '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":0,"unit_price":20}]'::jsonb,
       null, '[]'::jsonb, null) $$,
  '%quantity must be positive%', 'zero quantity is rejected');

select throws_like(
  $$ select record_sale(
       '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":-1}]'::jsonb,
       null, '[]'::jsonb, null) $$,
  '%price must be >= 0%', 'negative price is rejected');

-- ---------------------------------------------------------------------------
-- Split tender: gift card + credit.
-- ---------------------------------------------------------------------------
create temp table split_sale as
select record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb,
  null,
  '[{"method":"gift_card","amount":10,"gift_card_id":"00000000-0000-0000-0000-0000000000e1"},
    {"method":"credit","amount":11.65}]'::jsonb,
  null) as id;

select is((select payment_method from sales where id = (select id from split_sale)),
          'split', 'two tenders are summarized as split');
select is((select balance from gift_card_balance where gift_card_id = '00000000-0000-0000-0000-0000000000e1'),
          40::numeric, 'gift card is debited by the amount tendered');
select is((select user_id from gift_card_txns where sale_id = (select id from split_sale)),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'gift card redemption records the staff member');

select throws_like(
  $$ select record_sale(
       '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":3,"unit_price":20}]'::jsonb,
       null,
       '[{"method":"gift_card","amount":64.95,"gift_card_id":"00000000-0000-0000-0000-0000000000e1"}]'::jsonb,
       null) $$,
  '%Gift card balance%is less than%', 'cannot spend more than the gift card balance');

-- ---------------------------------------------------------------------------
-- Store credit.
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select record_sale(
       '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb,
       null, '[{"method":"store_credit","amount":21.65}]'::jsonb, null) $$,
  '%Store credit needs a customer%', 'store credit requires a customer on the sale');

create temp table credit_sale as
select record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb,
  '00000000-0000-0000-0000-0000000000c1',
  '[{"method":"store_credit","amount":21.65}]'::jsonb, null) as id;

select is((select balance from customer_store_credit where customer_id = '00000000-0000-0000-0000-0000000000c1'),
          3.35::numeric, 'store credit is debited');
select is((select user_id from store_credit_txns where sale_id = (select id from credit_sale)),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'store credit redemption records the staff member');

-- ---------------------------------------------------------------------------
-- Gift card load: never taxed; loading an empty card assigns the customer.
-- ---------------------------------------------------------------------------
insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e2', 'GC-TEST-2');
create temp table load_sale as
select record_sale(
  '[{"gift_card_id":"00000000-0000-0000-0000-0000000000e2","qty":1,"unit_price":75}]'::jsonb,
  '00000000-0000-0000-0000-0000000000c1',
  '[{"method":"cash","amount":75}]'::jsonb, null) as id;

select is((select tax from sales where id = (select id from load_sale)), 0::numeric(12,2),
          'gift card loads are not taxed');
select is((select balance from gift_card_balance where gift_card_id = '00000000-0000-0000-0000-0000000000e2'),
          75::numeric, 'loading credits the card');
select is((select customer_id from gift_cards where id = '00000000-0000-0000-0000-0000000000e2'),
          '00000000-0000-0000-0000-0000000000c1'::uuid, 'loading an empty card assigns it to the sale customer');

-- ---------------------------------------------------------------------------
-- String job line: marks the job paid; stringing untaxed unless enabled.
-- ---------------------------------------------------------------------------
create temp table job_sale as
select record_sale(
  '[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":30}]'::jsonb,
  '00000000-0000-0000-0000-0000000000c1',
  '[{"method":"cash","amount":30}]'::jsonb, null) as id;

select is((select paid_sale_id from string_jobs where id = '00000000-0000-0000-0000-000000000f01'),
          (select id from job_sale), 'paying a job stamps paid_sale_id');
select is((select tax from sales where id = (select id from job_sale)), 0::numeric(12,2),
          'stringing is not taxed when tax_stringing is off');

select tests.clear_authentication();
update settings set tax_stringing = true where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

create temp table taxed_job_sale as
select record_sale(
  '[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":30}]'::jsonb,
  null, '[{"method":"cash","amount":32.48}]'::jsonb, null) as id;
select is((select tax from sales where id = (select id from taxed_job_sale)), 2.48::numeric(12,2),
          'stringing is taxed when tax_stringing is on');

-- ---------------------------------------------------------------------------
-- Serialized racquet units.
-- ---------------------------------------------------------------------------
select is((select on_hand from product_stock where product_id = '00000000-0000-0000-0000-0000000000b2'),
          2::numeric, 'serialized on-hand counts in-stock units');
select is((select created_by from product_units where barcode = 'RQ-UNIT-1'),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'received unit records who received it');

select throws_like(
  $$ select record_sale(
       '[{"product_id":"00000000-0000-0000-0000-0000000000b2","qty":1,"unit_price":250}]'::jsonb,
       null, '[{"method":"credit","amount":270.63}]'::jsonb, null) $$,
  '%serialized; a product_unit_id is required%', 'a serialized product must be sold by unit');

create temp table unit_sale as
select record_sale(
  jsonb_build_array(jsonb_build_object(
    'product_id', '00000000-0000-0000-0000-0000000000b2',
    'product_unit_id', (select id from product_units where barcode = 'RQ-UNIT-1'),
    'qty', 1, 'unit_price', 250)),
  '00000000-0000-0000-0000-0000000000c1',
  '[{"method":"credit","amount":270.63}]'::jsonb, null) as id;

select results_eq(
  $$ select status, sale_id, customer_id from product_units where barcode = 'RQ-UNIT-1' $$,
  $$ select 'sold'::text, (select id from unit_sale), '00000000-0000-0000-0000-0000000000c1'::uuid $$,
  'selling a unit marks it sold to the customer on that sale');
select is((select on_hand from product_stock where product_id = '00000000-0000-0000-0000-0000000000b2'),
          1::numeric, 'one unit left in stock');
select is((select count(*)::int from inventory_txns where sale_id = (select id from unit_sale)),
          0, 'serialized sales write no quantity stock entry');

select throws_like(
  format($$ select record_sale(
       '[{"product_id":"00000000-0000-0000-0000-0000000000b2","product_unit_id":"%s","qty":1,"unit_price":250}]'::jsonb,
       null, '[{"method":"credit","amount":270.63}]'::jsonb, null) $$,
       (select id from product_units where barcode = 'RQ-UNIT-1')),
  '%is not in stock%', 'a sold unit cannot be sold again');

select throws_like(
  format($$ select record_sale(
       '[{"product_id":"00000000-0000-0000-0000-0000000000b2","product_unit_id":"%s","qty":2,"unit_price":250}]'::jsonb,
       null, '[{"method":"credit","amount":541.25}]'::jsonb, null) $$,
       (select id from product_units where barcode is null and product_id = '00000000-0000-0000-0000-0000000000b2')),
  '%qty must be 1%', 'serialized lines are always qty 1');

-- ---------------------------------------------------------------------------
-- Oversell: allowed by default, blocked when the setting is on.
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ select record_sale(
       '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":50,"unit_price":0}]'::jsonb,
       null, '[]'::jsonb, null) $$,
  'overselling is allowed when block_oversell is off');

select tests.clear_authentication();
update settings set block_oversell = true where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

select throws_like(
  $$ select record_sale(
       '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":0}]'::jsonb,
       null, '[]'::jsonb, null) $$,
  '%Not enough stock%', 'overselling is blocked when block_oversell is on');

-- ---------------------------------------------------------------------------
-- Unknown references.
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select record_sale(
       '[{"product_id":"00000000-0000-0000-0000-00000000dead","qty":1,"unit_price":1}]'::jsonb,
       null, '[]'::jsonb, null) $$,
  '%Unknown product_id%', 'unknown product is rejected');
select throws_like(
  $$ select record_sale(
       '[{"gift_card_id":"00000000-0000-0000-0000-00000000dead","qty":1,"unit_price":1}]'::jsonb,
       null, '[]'::jsonb, null) $$,
  '%Unknown gift_card_id%', 'unknown gift card is rejected');

select * from finish();
rollback;
