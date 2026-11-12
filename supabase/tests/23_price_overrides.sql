-- Price overrides: a line sold at a price other than its list price (the
-- catalog price, or the string job's price) needs a reason, and the sale keeps
-- both prices and the reason (Phase 2A).
begin;
\ir helpers/setup.psql

select plan(27);

-- Fixtures: a product with no catalog price, a racquet unit, a string job at
-- $30 and a gift card. Fixture products: strings b1 at $20, racquet b2 at $250.
insert into products (id, category_id, brand, name, sell_price)
select '00000000-0000-0000-0000-0000000000b9', id, 'TestBrand', 'Unpriced Demo', null
  from categories where name = 'Strings';
select receive_units('00000000-0000-0000-0000-0000000000b2', '["PO-UNIT-1"]'::jsonb);
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Override Frame');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, price)
values ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 55, 53, 30);
create temp table card as select ensure_gift_card('PO-CARD-1', null) as id;

-- ---------------------------------------------------------------------------
-- The quote: list prices, and changed prices that need a reason
-- ---------------------------------------------------------------------------
create temp table q1 as
select quote_sale(jsonb_build_array(
  '{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":2,"unit_price":20}'::jsonb,
  '{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":30}'::jsonb,
  jsonb_build_object('gift_card_id', (select id from card), 'qty', 1, 'unit_price', 25),
  '{"product_id":"00000000-0000-0000-0000-0000000000b9","qty":1,"unit_price":12}'::jsonb), null) as q;
select is((select jsonb_agg(l->'list_price') from q1, jsonb_array_elements(q->'lines') l),
          '[20.00, 30.00, null, null]'::jsonb,
          'each line carries its list price: catalog, job price, none for a gift card or an unpriced item');
select is((select q->'problems' from q1), '[]'::jsonb,
          'list prices, a gift card at any amount and an unpriced item need no reason');

select is(quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":15}]'::jsonb, null)->'problems',
          '[{"line": 0, "message": "Price changed from $20.00: give a reason"}]'::jsonb,
          'a lower price without a reason is a problem');
select is(quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":22.50}]'::jsonb, null)->'problems',
          '[{"line": 0, "message": "Price changed from $20.00: give a reason"}]'::jsonb,
          'so is a higher one');
select is(quote_sale('[{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":25}]'::jsonb, null)->'problems',
          '[{"line": 0, "message": "Price changed from $30.00: give a reason"}]'::jsonb,
          'so is a string job charged at a different price than the job''s');
select is(quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":15,"price_reason":"   "}]'::jsonb, null)->'problems',
          '[{"line": 0, "message": "Price changed from $20.00: give a reason"}]'::jsonb,
          'a blank reason is no reason');

create temp table q2 as
select quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":15,"price_reason":"  Price match "}]'::jsonb, null) as q;
select is((select q->'problems' from q2), '[]'::jsonb, 'a reason clears the problem');
select is((select q->'lines'->0 from q2),
          '{"line_total": 15, "taxable": true, "list_price": 20.00, "price_changed": true, "price_reason": "Price match",
            "price_before_discount": 15, "line_discount_each": 0, "ticket_discount_each": 0, "unit_price": 15,
            "discount_reason": null, "discount_percent": 25.00}'::jsonb,
          'the quote shows the change and the trimmed reason');
select is((select (q->>'total')::numeric from q2), 16.24, 'and totals the changed price');

select is(quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b2","qty":1,"unit_price":200}]'::jsonb, null)->'problems',
          '[{"line": 0, "message": "This item is tracked by unit: scan the unit being sold"}]'::jsonb,
          'a line that can''t be sold gives that reason, not a price one');

select throws_like(
  format($$ select quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":15,"price_reason":"%s"}]'::jsonb, null) $$,
         repeat('x', 201)),
  '%at most 200 characters%', 'a reason is at most 200 characters');

-- ---------------------------------------------------------------------------
-- Recording the sale
-- ---------------------------------------------------------------------------
select throws_like(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20},
                          {"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":15}]'::jsonb,
                        null, '[{"method":"cash","amount":37.89}]'::jsonb, null) $$,
  'Price changed from $20.00 on line 2: give a reason', 'a sale with a changed price and no reason is refused, naming the line');
select is((select count(*) from sales), 0::bigint, '... and nothing is saved');

create temp table sale1 as
select record_sale(jsonb_build_array(
  '{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":2,"unit_price":15,"price_reason":" Damaged "}'::jsonb,
  '{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20,"price_reason":"ignored"}'::jsonb,
  jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000b2',
                     'product_unit_id', (select id from product_units where barcode = 'PO-UNIT-1'),
                     'qty', 1, 'unit_price', 275, 'price_reason', 'Strung with premium'),
  '{"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":25,"price_reason":"Price match"}'::jsonb,
  jsonb_build_object('gift_card_id', (select id from card), 'qty', 1, 'unit_price', 25),
  '{"product_id":"00000000-0000-0000-0000-0000000000b9","qty":1,"unit_price":12}'::jsonb),
  '00000000-0000-0000-0000-0000000000c1', '[{"method":"cash","amount":414.80}]'::jsonb, null) as id;
grant select on sale1 to authenticated;

select results_eq(
  $$ select unit_price, list_price, price_reason from sale_lines
      where sale_id = (select id from sale1) order by product_id nulls last, string_job_id nulls last, unit_price $$,
  $$ values (15.00::numeric, 20.00::numeric, 'Damaged'::text),
            (20.00, 20.00, null),
            (275.00, 250.00, 'Strung with premium'),
            (12.00, null, null),
            (25.00, 30.00, 'Price match'),
            (25.00, null, null) $$,
  'each line keeps its list price, and a trimmed reason only where the price changed');
select is((select subtotal from sales where id = (select id from sale1)), 387.00::numeric,
          'the sale is totalled at the prices charged');
select is((select price from string_jobs where id = '00000000-0000-0000-0000-000000000f01'), 25.00::numeric,
          'the string job takes the price charged, as before');
select is((select user_id from sales where id = (select id from sale1)), '00000000-0000-0000-0000-0000000000a1'::uuid,
          'who changed the prices is who rang up the sale');

select throws_like(
  format($$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":15,"price_reason":"%s"}]'::jsonb,
                               null, '[{"method":"cash","amount":16.24}]'::jsonb, null) $$, repeat('x', 201)),
  '%at most 200 characters%', 'record_sale holds reasons to 200 characters too');

-- The catalog price at the time of the sale is what's kept.
select tests.clear_authentication();
update products set sell_price = 18 where id = '00000000-0000-0000-0000-0000000000b1';
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select is(quote_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":18}]'::jsonb, null)->'problems',
          '[]'::jsonb, 'after a catalog price change, the new price is the list price');
select is((select list_price from sale_lines where sale_id = (select id from sale1) and unit_price = 15),
          20.00::numeric, '... and earlier sales keep the list price they were sold against');

-- ---------------------------------------------------------------------------
-- The report
-- ---------------------------------------------------------------------------
create temp table report as
select * from sales_summary(now() - interval '1 hour', now() + interval '1 hour');
select is((select price_changes from report), 3, 'the report counts the lines whose price changed');
select is((select price_change_total from report), 10.00::numeric,
          'and what they came to: -$10 on the strings, +$25 on the racquet, -$5 on the job');
select is((select gross from report), 362.00::numeric, 'gross is unchanged by the new columns');

-- ---------------------------------------------------------------------------
-- Columns and quick picks
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
select throws_ok(
  $$ update sale_lines set price_reason = ' padded ' where sale_id = (select id from sale1) and unit_price = 15 $$,
  '23514', null, 'a saved reason is always trimmed');
select throws_ok(
  $$ update sale_lines set list_price = -1 where sale_id = (select id from sale1) and unit_price = 15 $$,
  '23514', null, 'a list price can''t be negative');
select is((select array_agg(value order by value) from lookup_values where kind = 'price_reason'),
          array['Damaged', 'Price match', 'Staff'], 'the register has quick-pick reasons to start with');
select ok(exists (select 1 from information_schema.columns
                   where table_name = 'sale_lines' and column_name = 'list_price' and numeric_scale = 2),
          'list_price is stored to the cent');

select * from finish();
rollback;
