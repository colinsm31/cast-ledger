-- quote_sale: the total the register shows before payment is the total
-- record_sale requires, and lines that can't be sold are listed up front
-- (Phase 2A, server-side quote).
begin;
\ir helpers/setup.psql

select plan(32);

-- Fixtures: two racquet units (one is sold below), two string jobs, a gift card.
select receive_units('00000000-0000-0000-0000-0000000000b2', '["QT-UNIT-1", "QT-UNIT-2"]'::jsonb);
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Quote Frame'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1', 'Second Frame');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 55, 53, 30),
       ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000f2',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 55, 53, 30);
create temp table card as select ensure_gift_card('QT-CARD-1', null) as id;

-- ---------------------------------------------------------------------------
-- Totals
-- ---------------------------------------------------------------------------
create temp table q1 as
select quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":2,"unit_price":20}]'::jsonb, null) as q;
select is((select (q->>'subtotal')::numeric from q1), 40.00, 'subtotal is qty × price');
select is((select (q->>'tax')::numeric from q1), 3.30, 'products are taxed at the shop rate (8.25%)');
select is((select (q->>'total')::numeric from q1), 43.30, 'total is subtotal + tax');
select is((select (q->>'tax_rate')::numeric from q1), 8.250, 'the quote says which rate it used');
select is((select q->'problems' from q1), '[]'::jsonb, 'a sellable ticket has no problems');

select is((quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":102}]'::jsonb, null)->>'tax')::numeric,
          8.42, 'tax rounds half up like the register ($102 × 8.25% = 8.415 → 8.42)');

create temp table q2 as
select quote_sale(jsonb_build_array(
  '{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":30}'::jsonb,
  jsonb_build_object('gift_card_id', (select id from card), 'qty', 1, 'unit_price', 50)), null) as q;
select is((select (q->>'tax')::numeric from q2), 0.00, 'stringing (not taxed here) and gift card loads carry no tax');
select is((select jsonb_agg(jsonb_build_object('line_total', l->'line_total', 'taxable', l->'taxable'))
             from q2, jsonb_array_elements(q->'lines') l),
          '[{"line_total": 30, "taxable": false}, {"line_total": 50, "taxable": false}]'::jsonb,
          'each line says whether it is taxed');

-- ---------------------------------------------------------------------------
-- Problems are listed, not raised
-- ---------------------------------------------------------------------------
-- Sell QT-UNIT-1 and pay job f02, so a ticket holding them can't be sold again.
select record_sale(jsonb_build_array(
  jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000b2',
                     'product_unit_id', (select id from product_units where barcode = 'QT-UNIT-1'),
                     'qty', 1, 'unit_price', 250),
  '{"string_job_id":"00000000-0000-0000-0000-000000000f02","qty":1,"unit_price":30}'::jsonb),
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":300.63}]'::jsonb, null);

create temp table q3 as
select quote_sale(jsonb_build_array(
  jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000b2',
                     'product_unit_id', (select id from product_units where barcode = 'QT-UNIT-1'),
                     'qty', 1, 'unit_price', 250),
  '{"product_id":"00000000-0000-0000-0000-0000000000b2","qty":1,"unit_price":250}'::jsonb,
  '{"string_job_id":"00000000-0000-0000-0000-000000000f02","qty":1,"unit_price":30}'::jsonb,
  '{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":30}'::jsonb,
  '{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":30}'::jsonb,
  '{"product_id":"00000000-0000-0000-0000-00000000dead","qty":1,"unit_price":5}'::jsonb,
  '{"gift_card_id":"00000000-0000-0000-0000-00000000dead","qty":1,"unit_price":5}'::jsonb), null) as q;
select is((select jsonb_array_length(q->'problems') from q3), 6, 'every unsellable line is listed at once');
select is((select q->'problems'->0 from q3),
          '{"line": 0, "message": "This unit is no longer in stock (sold)"}'::jsonb, 'a unit already sold');
select is((select q->'problems'->1 from q3),
          '{"line": 1, "message": "This item is tracked by unit: scan the unit being sold"}'::jsonb,
          'a tracked item with no unit');
select is((select q->'problems'->2 from q3),
          '{"line": 2, "message": "This string job is already paid"}'::jsonb, 'a job already paid');
select is((select q->'problems'->3 from q3),
          '{"line": 4, "message": "This string job is on the ticket more than once"}'::jsonb,
          'the second copy of a job (the first copy is fine)');
select is((select q->'problems'->4 from q3),
          '{"line": 5, "message": "This item is no longer in the catalog"}'::jsonb, 'an unknown product');
select is((select q->'problems'->5 from q3),
          '{"line": 6, "message": "This gift card is no longer on file"}'::jsonb, 'an unknown gift card');
select is((select (q->>'total')::numeric from q3), 641.66, 'the totals are still given alongside the problems');

select cancel_string_job('00000000-0000-0000-0000-000000000f01');
select is(quote_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":30}]'::jsonb, null)->'problems',
          '[{"line": 0, "message": "This string job was cancelled"}]'::jsonb, 'a cancelled job');

-- Overselling: allowed by default, so 25 of a product with 10 on hand is fine…
select is(quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":25,"unit_price":20}]'::jsonb, null)->'problems',
          '[]'::jsonb, 'overselling allowed: no stock problem');
-- …but with it blocked, lines of one product are added up against what's on hand.
select tests.clear_authentication();
update settings set block_oversell = true where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select is(quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":6,"unit_price":20},
                       {"product_id":"00000000-0000-0000-0000-0000000000b1","qty":5,"unit_price":20}]'::jsonb, null)->'problems',
          '[{"line": 0, "message": "Not enough stock: 10 on hand, 11 on this ticket"}]'::jsonb,
          'overselling blocked: two lines of one product are counted together');
select is(quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":10,"unit_price":20}]'::jsonb, null)->'problems',
          '[]'::jsonb, '... and exactly what is on hand is fine');

-- ---------------------------------------------------------------------------
-- Badly formed input raises, as record_sale does
-- ---------------------------------------------------------------------------
select throws_like($$ select quote_sale('[]'::jsonb, null) $$, '%at least one line%', 'an empty ticket');
select throws_like($$ select quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":-1}]'::jsonb, null) $$,
                   '%price must be >= 0%', 'a negative price');
select throws_like($$ select quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":1.005}]'::jsonb, null) $$,
                   '%more than 2 decimal places%', 'a price with part of a cent');
select throws_like($$ select quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":5}]'::jsonb,
                                        '00000000-0000-0000-0000-00000000dead') $$,
                   '%Unknown customer_id%', 'an unknown customer');

-- ---------------------------------------------------------------------------
-- The quote and the saved sale agree; the quote writes nothing
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
update settings set block_oversell = false where id;
create temp table counts_before as
select (select count(*) from sales) as sales, (select count(*) from inventory_txns) as txns;
grant select on counts_before to authenticated;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

create temp table q4 as
select quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":3,"unit_price":19.99,"price_reason":"Price match"}]'::jsonb, null) as q;
select is((select count(*) from sales), (select sales from counts_before), 'quoting records no sale');
select is((select count(*) from inventory_txns), (select txns from counts_before), 'quoting moves no stock');

create temp table s4 as
select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":3,"unit_price":19.99,"price_reason":"Price match"}]'::jsonb, null,
                   jsonb_build_array(jsonb_build_object('method', 'cash', 'amount',
                     (quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":3,"unit_price":19.99,"price_reason":"Price match"}]'::jsonb, null)->>'total')::numeric)),
                   null) as id;
select results_eq(
  $$ select subtotal, tax, tax_rate from sales where id = (select id from s4) $$,
  $$ values (59.97::numeric, 4.95::numeric, 8.250::numeric) $$,
  'paying the quoted total records the sale at the quoted figures');

-- The rate changes while the ticket is open: the old amount is refused with a
-- message saying why, and a new quote has the new total.
select tests.clear_authentication();
update settings set tax_rate = 9 where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb, null,
                        '[{"method":"cash","amount":21.65}]'::jsonb, null) $$,
  'Payments ($21.65) must equal the sale total ($21.80). The total may have changed%',
  'paying the old total after a rate change is refused, saying the total may have changed');
select is((quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb, null)->>'total')::numeric,
          21.80, 'a fresh quote has the new total');

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
select tests.create_staff('00000000-0000-0000-0000-0000000000a3', 'pending@test.local', 'pending');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a3');
select throws_ok(
  $$ select quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]'::jsonb, null) $$,
  '42501', null, 'an account waiting for approval can''t get a quote');
select tests.clear_authentication();

select ok(not has_function_privilege('anon', 'quote_sale(jsonb, uuid, jsonb, uuid)', 'execute'),
          'signed-out visitors can''t call quote_sale');
select ok(not has_function_privilege('authenticated', 'sale_totals(jsonb, jsonb, boolean)', 'execute')
          and not has_function_privilege('authenticated', 'require_sale_line(jsonb)', 'execute'),
          'the internal helpers aren''t callable by signed-in users');

select * from finish();
rollback;
