-- Phase 1B money-path guards: a string job can't be charged twice, refund
-- payment-type changes need a reason, and refund tax never exceeds what the
-- sale charged. (Concurrent access is covered by scripts/test-concurrency.sh,
-- which needs two real connections.)
begin;
\ir helpers/setup.psql

select plan(21);

insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Frame A'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'Frame B');
insert into string_jobs (id, customer_racket_id, price, status) values
  ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1', 30, 'entered'),
  ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000f2', 30, 'entered'),
  ('00000000-0000-0000-0000-000000000f03', '00000000-0000-0000-0000-0000000000f1', 30, 'cancelled');
insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e1', 'GC-GUARD');
insert into gift_card_txns (gift_card_id, amount, reason) values ('00000000-0000-0000-0000-0000000000e1', 100, 'load');
insert into products (id, category_id, name, sell_price) values
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000d1', 'Overgrip', 5.05);
insert into inventory_txns (txn_type, product_id, qty) values ('receive', '00000000-0000-0000-0000-0000000000b3', 10);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------------
-- String jobs can't be charged twice
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":30}]'::jsonb,
                        null, '[{"method":"cash","amount":30}]'::jsonb, null) $$,
  'an unpaid job can be charged');
select throws_like(
  $$ select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":30}]'::jsonb,
                        null, '[{"method":"cash","amount":30}]'::jsonb, null) $$,
  '%is already paid%', 'a paid job cannot be charged again');
select throws_like(
  $$ select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f02","qty":1,"unit_price":30},
                          {"string_job_id":"00000000-0000-0000-0000-000000000f02","qty":1,"unit_price":30}]'::jsonb,
                        null, '[{"method":"cash","amount":60}]'::jsonb, null) $$,
  '%on this ticket more than once%', 'the same job cannot be on one ticket twice');
select throws_like(
  $$ select record_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f03","qty":1,"unit_price":30}]'::jsonb,
                        null, '[{"method":"cash","amount":30}]'::jsonb, null) $$,
  '%was cancelled%', 'a cancelled job cannot be charged');

select throws_like(
  $$ update string_jobs set price = 10 where id = '00000000-0000-0000-0000-000000000f01' $$,
  '%price of a paid string job%', 'a paid job''s price is locked');
select throws_ok(
  $$ update string_jobs set paid_sale_id = null where id = '00000000-0000-0000-0000-000000000f01' $$,
  '42501', null, 'staff cannot change which sale paid a job (only record_sale sets it)');
select tests.clear_authentication();
select throws_like(
  $$ update string_jobs set paid_sale_id = null where id = '00000000-0000-0000-0000-000000000f01' $$,
  '%already paid by sale%', 'even with full rights, a paid job stays linked to the sale that paid it');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok(
  $$ update string_jobs set price = 35 where id = '00000000-0000-0000-0000-000000000f02' $$,
  'an unpaid job''s price can still be edited');
-- A job needs a stringer before it's complete (0051).
update string_jobs set strung_by = 'Test Stringer' where id = '00000000-0000-0000-0000-000000000f01';
select lives_ok(
  $$ select advance_string_job('00000000-0000-0000-0000-000000000f01', 'complete') $$,
  'a paid job still moves through its statuses');

-- ---------------------------------------------------------------------------
-- Refund payment types: 2 strings @ $20 + 8.25% = $43.30, paid $20 cash + $23.30 credit
-- ---------------------------------------------------------------------------
create temp table mixed_sale as
select record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":2,"unit_price":20}]'::jsonb,
  '00000000-0000-0000-0000-0000000000c1',
  '[{"method":"cash","amount":20},{"method":"credit","amount":23.30}]'::jsonb, null) as id;
create temp table mixed_line as
select id from sale_lines where sale_id = (select id from mixed_sale);

create temp table same_type_refund as
select record_refund((select id from mixed_sale),
  jsonb_build_array(jsonb_build_object('sale_line_id', (select id from mixed_line), 'qty', 1)),
  '[{"method":"cash","amount":20},{"method":"credit","amount":1.65}]'::jsonb, null, null) as id;
select is((select method_change_reason from refunds where id = (select id from same_type_refund)), null,
          'refunding to the payment types the sale used needs no reason');

select throws_like(
  format($$ select record_refund('%s', '[{"sale_line_id":"%s","qty":1}]'::jsonb,
         '[{"method":"cash","amount":21.65}]'::jsonb, null, null) $$,
         (select id from mixed_sale), (select id from mixed_line)),
  '%payment-type change; give a reason%',
  'refunding more cash than the sale took (net of earlier refunds) needs a reason');
select throws_like(
  format($$ select record_refund('%s', '[{"sale_line_id":"%s","qty":1}]'::jsonb,
         '[{"method":"cash","amount":21.65}]'::jsonb, null, null, '   ') $$,
         (select id from mixed_sale), (select id from mixed_line)),
  '%give a reason%', 'a blank reason does not count');

create temp table changed_refund as
select record_refund((select id from mixed_sale),
  jsonb_build_array(jsonb_build_object('sale_line_id', (select id from mixed_line), 'qty', 1)),
  '[{"method":"cash","amount":21.65}]'::jsonb, null, null, 'customer prefers cash') as id;
select results_eq(
  $$ select method_change_reason, user_id from refunds where id = (select id from changed_refund) $$,
  $$ values ('customer prefers cash'::text, '00000000-0000-0000-0000-0000000000a1'::uuid) $$,
  'any staff member can change the payment type with a reason, which is recorded with their name');

-- The sale is now fully refunded: $20 cash + $1.65 credit, then $21.65 cash
-- with a reason. A follow-up refund on another sale must not inherit that.
create temp table follow_up_sale as
select record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":2,"unit_price":20}]'::jsonb, null,
  '[{"method":"cash","amount":5},{"method":"credit","amount":38.30}]'::jsonb, null) as id;
create temp table follow_up_line as select id from sale_lines where sale_id = (select id from follow_up_sale);
select lives_ok(
  format($$ select record_refund('%s', '[{"sale_line_id":"%s","qty":1}]'::jsonb,
         '[{"method":"cash","amount":21.65}]'::jsonb, null, null, 'card reader down') $$,
         (select id from follow_up_sale), (select id from follow_up_line)),
  'first refund: more cash than was taken, with a reason');
select lives_ok(
  format($$ select record_refund('%s', '[{"sale_line_id":"%s","qty":1}]'::jsonb,
         '[{"method":"credit","amount":21.65}]'::jsonb, null, null) $$,
         (select id from follow_up_sale), (select id from follow_up_line)),
  'a later refund to a type that still has room needs no reason, even after an earlier change');

-- Gift card back to a gift card is the same payment type.
create temp table gift_sale as
select record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb, null,
  '[{"method":"gift_card","amount":21.65,"gift_card_id":"00000000-0000-0000-0000-0000000000e1"}]'::jsonb, null) as id;
select lives_ok(
  format($$ select record_refund('%s', '[{"sale_line_id":"%s","qty":1}]'::jsonb,
         '[{"method":"gift_card","amount":21.65,"gift_card_id":"00000000-0000-0000-0000-0000000000e1"}]'::jsonb, null, null) $$,
         (select id from gift_sale), (select id from sale_lines where sale_id = (select id from gift_sale))),
  'refunding a gift card purchase back to a gift card needs no reason');
select is((select balance from gift_card_balance where gift_card_id = '00000000-0000-0000-0000-0000000000e1'),
          100::numeric, 'and restores the card balance');

-- ---------------------------------------------------------------------------
-- Refund tax is cumulative: 2 × $5.05 at 8.25% charges $0.83 tax once.
-- ---------------------------------------------------------------------------
create temp table small_sale as
select record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b3","qty":2,"unit_price":5.05}]'::jsonb, null,
  '[{"method":"cash","amount":10.93}]'::jsonb, null) as id;
select is((select tax from sales where id = (select id from small_sale)), 0.83::numeric(12,2),
          'the sale charges $0.83 tax on $10.10');

create temp table small_line as select id from sale_lines where sale_id = (select id from small_sale);
create temp table small_refund_1 as
select record_refund((select id from small_sale),
  jsonb_build_array(jsonb_build_object('sale_line_id', (select id from small_line), 'qty', 1)),
  '[{"method":"cash","amount":5.47}]'::jsonb, null, null) as id;
select is((select tax from refunds where id = (select id from small_refund_1)), 0.42::numeric(12,2),
          'the first single-item refund returns $0.42 tax');

select throws_like(
  format($$ select record_refund('%s', '[{"sale_line_id":"%s","qty":1}]'::jsonb,
         '[{"method":"cash","amount":5.47}]'::jsonb, null, null) $$,
         (select id from small_sale), (select id from small_line)),
  '%must equal the refund total (5.46)%', 'the second refund is $5.46, not $5.47');

create temp table small_refund_2 as
select record_refund((select id from small_sale),
  jsonb_build_array(jsonb_build_object('sale_line_id', (select id from small_line), 'qty', 1)),
  '[{"method":"cash","amount":5.46}]'::jsonb, null, null) as id;
select is((select sum(tax) from refunds where sale_id = (select id from small_sale)), 0.83::numeric,
          'separate refunds give back exactly the tax the sale charged');

select * from finish();
rollback;
