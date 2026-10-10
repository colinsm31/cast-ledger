-- record_refund: partial returns, original tax rate, restocking, refund tenders,
-- over-return protection, unsupported line types, and the sales summary.
-- The original sale is paid by credit, so the cash / store credit / gift card
-- refunds below are payment-type changes and carry a reason (0038).
begin;
\ir helpers/setup.psql

select plan(18);

insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Old Frame');
insert into string_jobs (id, customer_racket_id, price) values
  ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1', 30);
insert into product_units (id, product_id, barcode) values
  ('00000000-0000-0000-0000-0000000000a9', '00000000-0000-0000-0000-0000000000b2', 'RQ-REFUND-1');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- 3 strings @ $20 at 8.25% = 60 + 4.95, plus a stringing line ($30, untaxed)
-- and a racquet unit ($250 + 20.63).
create temp table original_sale as
select record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":3,"unit_price":20},
    {"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":30},
    {"product_id":"00000000-0000-0000-0000-0000000000b2","product_unit_id":"00000000-0000-0000-0000-0000000000a9","qty":1,"unit_price":250}]'::jsonb,
  '00000000-0000-0000-0000-0000000000c1',
  '[{"method":"credit","amount":365.58}]'::jsonb, null) as id;

create temp table lines as
select
  (select id from sale_lines where sale_id = (select id from original_sale) and product_id = '00000000-0000-0000-0000-0000000000b1') as string_line,
  (select id from sale_lines where sale_id = (select id from original_sale) and string_job_id is not null) as job_line,
  (select id from sale_lines where sale_id = (select id from original_sale) and product_unit_id is not null) as unit_line;

-- The shop changes its tax rate after the sale; refunds must use the old rate.
select tests.clear_authentication();
update settings set tax_rate = 10 where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

create temp table first_refund as
select record_refund(
  (select id from original_sale),
  jsonb_build_array(jsonb_build_object('sale_line_id', (select string_line from lines), 'qty', 1)),
  '[{"method":"cash","amount":21.65}]'::jsonb,
  'wrong gauge', null, 'card reader down') as id;

select results_eq(
  $$ select subtotal, tax, reason from refunds where id = (select id from first_refund) $$,
  $$ values (20.00::numeric(12,2), 1.65::numeric(12,2), 'wrong gauge'::text) $$,
  'refund is taxed at the original sale rate (8.25%), not the current one (10%)');
select is((select on_hand from product_stock where product_id = '00000000-0000-0000-0000-0000000000b1'),
          8::numeric, 'returned string goes back on hand (10 − 3 + 1)');
select is((select user_id from refunds where id = (select id from first_refund)),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'refund records the staff member');
select is((select method_change_reason from refunds where id = (select id from first_refund)),
          'card reader down', 'a payment-type change records its reason');
select is((select user_id from inventory_txns where txn_type = 'return'),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'return stock entry records the staff member');

-- Refund to store credit and to a gift card.
create temp table second_refund as
select record_refund(
  (select id from original_sale),
  jsonb_build_array(jsonb_build_object('sale_line_id', (select string_line from lines), 'qty', 1)),
  '[{"method":"store_credit","amount":21.65}]'::jsonb, null, null, 'customer asked for credit') as id;
select is((select balance from customer_store_credit where customer_id = '00000000-0000-0000-0000-0000000000c1'),
          21.65::numeric, 'refund to store credit issues credit to the sale customer');
select is((select user_id from store_credit_txns where reason = 'refund'),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'store credit refund records the staff member');

insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e3', 'GC-REFUND');
select lives_ok(
  format($$ select record_refund('%s',
       '[{"sale_line_id":"%s","qty":1}]'::jsonb,
       '[{"method":"gift_card","amount":21.65,"gift_card_id":"00000000-0000-0000-0000-0000000000e3"}]'::jsonb,
       null, null, 'gift for a friend') $$,
       (select id from original_sale), (select string_line from lines)),
  'refund onto a gift card');
select is((select balance from gift_card_balance where gift_card_id = '00000000-0000-0000-0000-0000000000e3'),
          21.65::numeric, 'gift card refund loads the card');

-- All 3 strings are now returned.
select throws_like(
  format($$ select record_refund('%s', '[{"sale_line_id":"%s","qty":1}]'::jsonb,
       '[{"method":"cash","amount":21.65}]'::jsonb, null, null) $$,
       (select id from original_sale), (select string_line from lines)),
  '%Cannot return 1 of line (only 0 remaining)%', 'a line cannot be returned more times than it was sold');

select throws_like(
  format($$ select record_refund('%s', '[{"sale_line_id":"%s","qty":1}]'::jsonb,
       '[{"method":"cash","amount":30}]'::jsonb, null, null) $$,
       (select id from original_sale), (select job_line from lines)),
  '%Only product lines can be returned%', 'stringing lines are not refundable yet');

select throws_like(
  format($$ select record_refund('%s', '[{"sale_line_id":"%s","qty":1}]'::jsonb,
       '[{"method":"credit","amount":270.63}]'::jsonb, null, null) $$,
       (select id from original_sale), (select unit_line from lines)),
  '%serialized%not supported yet%', 'serialized unit returns are not supported yet');

select throws_like(
  format($$ select record_refund('%s', '[]'::jsonb, '[]'::jsonb, null, null) $$, (select id from original_sale)),
  '%at least one line%', 'a refund needs at least one line');

select throws_like(
  $$ select record_refund('00000000-0000-0000-0000-00000000dead',
       '[{"sale_line_id":"00000000-0000-0000-0000-00000000dead","qty":1}]'::jsonb, '[]'::jsonb, null, null) $$,
  '%Unknown sale%', 'unknown sale is rejected');

-- A second sale to check the payment-total rule without exhausting the line.
create temp table second_sale as
select record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb,
  null, '[{"method":"cash","amount":22.00}]'::jsonb, null) as id;
select throws_like(
  format($$ select record_refund('%s',
       '[{"sale_line_id":"%s","qty":1}]'::jsonb, '[{"method":"cash","amount":5}]'::jsonb, null, null) $$,
       (select id from second_sale),
       (select id from sale_lines where sale_id = (select id from second_sale))),
  '%must equal the refund total%', 'refund payments must equal the refund total');
select throws_like(
  format($$ select record_refund('%s',
       '[{"sale_line_id":"%s","qty":1}]'::jsonb, '[{"method":"store_credit","amount":22}]'::jsonb, null, null) $$,
       (select id from second_sale),
       (select id from sale_lines where sale_id = (select id from second_sale))),
  '%needs a customer%', 'store credit refund requires a customer on the sale');

-- ---------------------------------------------------------------------------
-- sales_summary nets refunds out of receipts and per-tender totals.
-- Sales: 365.58 (credit) + 22.00 (cash, second sale at the new 10% rate).
-- Refunds: 3 × 21.65 (cash, store credit, gift card).
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select gross, tax, refunds, net, card, cash, store_credit, gift_card, num_tickets
       from sales_summary(now() - interval '1 hour', now() + interval '1 hour') $$,
  $$ values (360.00::numeric, 27.58::numeric, 64.95::numeric, 322.63::numeric,
             365.58::numeric, 0.35::numeric, -21.65::numeric, -21.65::numeric, 2) $$,
  'sales_summary: gross, tax, refunds, net and per-tender totals');

select is((select num_customers from sales_summary(now() - interval '1 hour', now() + interval '1 hour')),
          1, 'sales_summary counts distinct identified customers');

select * from finish();
rollback;
