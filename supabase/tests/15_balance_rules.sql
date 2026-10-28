-- Money inputs and balances (code review #5, #6, #7, #9): adding gift card
-- value or store credit needs a reason, a gift card refund goes back to the
-- card that paid (or needs a reason), customer history can't be deleted, and
-- every amount has whole cents.
begin;
\ir helpers/setup.psql

select plan(28);

-- Fixtures (as the test superuser):
--   cards GC-A (...e1) and GC-B (...e2), $200 each
--   customer ...c2 with only a racquet; ...c3 with a racquet that has a string job
--   sales of the $20 test string (8.25% tax, $21.65 each):
--     card_a   — 1 paid with GC-A
--     cash     — 1 paid in cash
--     split    — 2 paid $21.65 with GC-A and $21.65 cash
insert into gift_cards (id, code) values
  ('00000000-0000-0000-0000-0000000000e1', 'GC-A'),
  ('00000000-0000-0000-0000-0000000000e2', 'GC-B');
insert into gift_card_txns (gift_card_id, amount, reason) values
  ('00000000-0000-0000-0000-0000000000e1', 200, 'load'),
  ('00000000-0000-0000-0000-0000000000e2', 200, 'load');
insert into customers (id, first_name, last_name) values
  ('00000000-0000-0000-0000-0000000000c2', 'Only', 'Racquet'),
  ('00000000-0000-0000-0000-0000000000c3', 'Has', 'Jobs');
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c2', 'Frame Two'),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000c3', 'Frame Three');
insert into string_jobs (customer_racket_id, price, status)
values ('00000000-0000-0000-0000-0000000000f3', 30, 'entered');

create temp table t_sales (k text, id uuid);
insert into t_sales select 'card_a', record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb, null,
  '[{"method":"gift_card","amount":21.65,"gift_card_id":"00000000-0000-0000-0000-0000000000e1"}]'::jsonb, null);
insert into t_sales select 'cash', record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb,
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":21.65}]'::jsonb, null);
insert into t_sales select 'split', record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":2,"unit_price":20}]'::jsonb, null,
  '[{"method":"gift_card","amount":21.65,"gift_card_id":"00000000-0000-0000-0000-0000000000e1"},
    {"method":"cash","amount":21.65}]'::jsonb, null);
grant select on t_sales to authenticated;

-- One returned unit of a sale's line, refunded as given.
create function pg_temp.refund_one(p_key text, p_payments jsonb, p_change_reason text default null)
returns uuid
language sql
as $$
  select record_refund(
    s.id,
    jsonb_build_array(jsonb_build_object('sale_line_id', (select l.id from sale_lines l where l.sale_id = s.id), 'qty', 1)),
    p_payments, null, null, p_change_reason)
  from t_sales s where s.k = p_key;
$$;
grant execute on function pg_temp.refund_one(text, jsonb, text) to authenticated;

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------------
-- #5 Adding value needs a reason
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select adjust_gift_card('00000000-0000-0000-0000-0000000000e2', 10, null) $$,
  '%A reason is required to add value to a gift card%', 'adding value to a gift card needs a reason');
select throws_like(
  $$ select adjust_gift_card('00000000-0000-0000-0000-0000000000e2', 10, '   ') $$,
  '%A reason is required%', '... and a blank one doesn''t count');
select is(adjust_gift_card('00000000-0000-0000-0000-0000000000e2', 10, 'promo'), 210::numeric,
          'with a reason, the value is added');
select is(adjust_gift_card('00000000-0000-0000-0000-0000000000e2', -10, null), 200::numeric,
          'taking value off still needs no reason');
select throws_like(
  $$ select add_store_credit('00000000-0000-0000-0000-0000000000c1', 10, null) $$,
  '%A reason is required to add store credit%', 'manual store credit needs a reason');
select is(add_store_credit('00000000-0000-0000-0000-0000000000c1', 10, ' goodwill '), 10::numeric,
          'with a reason, the credit is added');

-- ---------------------------------------------------------------------------
-- #6 Gift card refunds go back to the card that paid
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select pg_temp.refund_one('card_a', '[{"method":"gift_card","amount":21.65,"gift_card_id":"00000000-0000-0000-0000-0000000000e2"}]') $$,
  '%Refunding more to gift card GC-B than the sale took that way%give a reason%',
  'refunding to a different card than the one that paid needs a reason');
select lives_ok(
  $$ select pg_temp.refund_one('card_a', '[{"method":"gift_card","amount":21.65,"gift_card_id":"00000000-0000-0000-0000-0000000000e2"}]',
                              'customer lost card A') $$,
  '... and with a reason it goes through');
select is((select method_change_reason from refunds where sale_id = (select id from t_sales where k = 'card_a')),
          'customer lost card A', '... and the reason is kept');
select throws_like(
  $$ select pg_temp.refund_one('cash', '[{"method":"gift_card","amount":21.65,"gift_card_id":"00000000-0000-0000-0000-0000000000e1"}]') $$,
  '%gift card GC-A%', 'refunding a cash sale to a card names the card');
select lives_ok(
  $$ select pg_temp.refund_one('split', '[{"method":"gift_card","amount":21.65,"gift_card_id":"00000000-0000-0000-0000-0000000000e1"}]') $$,
  'refunding to the card that paid needs no reason');
select throws_like(
  $$ select pg_temp.refund_one('split', '[{"method":"gift_card","amount":21.65,"gift_card_id":"00000000-0000-0000-0000-0000000000e1"}]') $$,
  '%gift card GC-A%', '... until what that card paid has been given back');

-- ---------------------------------------------------------------------------
-- #7 Customer history can't be deleted
-- ---------------------------------------------------------------------------
delete from customers where id = '00000000-0000-0000-0000-0000000000c2';
select is((select count(*)::int from customers where id = '00000000-0000-0000-0000-0000000000c2'), 1,
          'staff can''t delete a customer');
select tests.clear_authentication();
select is((select confdeltype::text from pg_constraint where conname = 'store_credit_txns_customer_id_fkey'), 'r',
          'store credit history blocks deleting its customer, instead of going with it');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select throws_like(
  $$ delete from customers where id = '00000000-0000-0000-0000-0000000000c1' $$,
  '%Pat Tester has sales, store credit history, so they can''t be deleted%',
  'an admin can''t delete a customer with sales or store credit, and is told why');
select throws_like(
  $$ delete from customers where id = '00000000-0000-0000-0000-0000000000c3' $$,
  '%string jobs history%', '... nor one with string jobs');
select lives_ok(
  $$ delete from customers where id = '00000000-0000-0000-0000-0000000000c2' $$,
  'an admin can delete a customer with no history');
select is((select count(*)::int from customer_rackets where id = '00000000-0000-0000-0000-0000000000f2'), 0,
          '... and their racquet, which had no string jobs, goes with them');
select tests.clear_authentication();
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------------
-- #9 Whole cents
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb, null,
       '[{"method":"cash","amount":7.217},{"method":"cash","amount":7.217},{"method":"cash","amount":7.216}]'::jsonb, null) $$,
  '%Payment amount 7.217 has more than 2 decimal places%',
  'payments that add up only before rounding are refused');
select throws_like(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":10.005}]'::jsonb, null,
       '[{"method":"cash","amount":10.83}]'::jsonb, null) $$,
  '%Price 10.005 has more than 2 decimal places%', 'a price with a fraction of a cent is refused');
select lives_ok(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20.000}]'::jsonb, null,
       '[{"method":"cash","amount":21.650}]'::jsonb, null) $$,
  'trailing zeros are fine');
select throws_like(
  $$ select pg_temp.refund_one('cash', '[{"method":"cash","amount":21.645},{"method":"cash","amount":0.005}]') $$,
  '%Refund amount 21.645 has more than 2 decimal places%', 'refund amounts too');
select throws_like(
  $$ select change_paid_string_job('00000000-0000-0000-0000-000000000999', null, null, null, null,
       '[{"method":"cash","amount":1.001}]'::jsonb, null) $$,
  '%Payment amount 1.001 has more than 2 decimal places%', 'string change payments too');
select throws_like(
  $$ select add_store_credit('00000000-0000-0000-0000-0000000000c1', 1.005, 'goodwill') $$,
  '%Store credit amount 1.005 has more than 2 decimal places%', 'store credit too');
select throws_like(
  $$ select adjust_gift_card('00000000-0000-0000-0000-0000000000e2', -1.001, null) $$,
  '%Adjustment -1.001 has more than 2 decimal places%', 'gift card adjustments too');
select throws_like(
  $$ select receive_stock('00000000-0000-0000-0000-0000000000b1', 5, 1.234, null, null) $$,
  '%Unit cost 1.234 has more than 2 decimal places%', 'a received unit cost too');
select ok(not has_function_privilege('authenticated', 'require_cents(numeric, text)', 'execute')
          and not has_function_privilege('authenticated', 'require_cents_each(jsonb, text, text)', 'execute'),
          'the cents helpers are internal');
select ok(not has_function_privilege('authenticated', 'guard_customer_delete()', 'execute'),
          'so is the customer delete guard');

select tests.clear_authentication();
select * from finish();
rollback;
