-- The sales report (code review #24): a gift card counts as a sale when it's
-- spent, not when it's sold; gift cards sold are reported on their own; the
-- tender totals still add up to net receipts; items are net of returns.
begin;
\ir helpers/setup.psql

select plan(9);

-- Fixtures: a $30 string job on Pat's racquet, and gift card GC-REPORT.
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000c1', 'Report Frame');
insert into string_jobs (id, customer_racket_id, price) values
  ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000f1', 30);
insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000000e1', 'GC-REPORT');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- 1. A $50 gift card sold for cash.
select record_sale(
  '[{"gift_card_id":"00000000-0000-0000-0000-0000000000e1","qty":1,"unit_price":50}]'::jsonb, null,
  '[{"method":"cash","amount":50}]'::jsonb, null);

-- 2. 2 strings ($40 + $3.30 tax) and the string job ($30, untaxed), paid with
--    the whole card and $23.30 cash.
create temp table goods_sale as
select record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":2,"unit_price":20},
    {"string_job_id":"00000000-0000-0000-0000-000000000f01","qty":1,"unit_price":30}]'::jsonb,
  '00000000-0000-0000-0000-0000000000c1',
  '[{"method":"gift_card","amount":50,"gift_card_id":"00000000-0000-0000-0000-0000000000e1"},
    {"method":"cash","amount":23.30}]'::jsonb, null) as id;
grant select on goods_sale to authenticated;

-- 3. One string returned for $21.65 cash.
select record_refund(
  (select id from goods_sale),
  (select jsonb_build_array(jsonb_build_object('sale_line_id', l.id, 'qty', 1))
     from sale_lines l where l.sale_id = (select id from goods_sale) and l.product_id is not null),
  '[{"method":"cash","amount":21.65}]'::jsonb, null, null, null);

create temp table report as
select * from sales_summary(now() - interval '1 hour', now() + interval '1 hour');
grant select on report to authenticated;

select is((select gross from report), 70.00::numeric,
          'gross is the strings and the string job, without the gift card sold');
select is((select gift_cards_sold from report), 50.00::numeric, 'the gift card sold is reported on its own');
select is((select tax from report), 3.30::numeric, 'tax is unchanged');
select is((select refunds from report), 21.65::numeric, 'refunds are unchanged');
select is((select net from report), 101.65::numeric,
          'net receipts are money taken in: gross + tax - refunds + gift cards sold');
select is((select card + cash + check_amt + store_credit + gift_card from report), (select net from report),
          '... which the tender totals add up to');
select is((select num_items from report), 1, 'items are net of returns, and the string job isn''t an item');
select is((select num_tickets from report), 2, 'both tickets are counted');

select tests.clear_authentication();
select ok(not has_function_privilege('anon', 'sales_summary(timestamptz, timestamptz)', 'execute'),
          'signed-out visitors can''t read the report');

select * from finish();
rollback;
