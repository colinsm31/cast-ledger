-- Returning items that sold for $0: a $0 sale, or a free item on a paid sale,
-- can be returned with no refund payments, and the items go back in stock
-- (Phase 2A). The server already allowed this; these checks keep it so.
begin;
\ir helpers/setup.psql

select plan(10);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- A $0 sale: two strings given away, no payments.
create temp table free_sale as
select record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":2,"unit_price":0,"price_reason":"Staff"}]'::jsonb,
  null, '[]'::jsonb, null) as id;
-- A paid sale with one free string: $20 + 8.25% tax.
create temp table mixed_sale as
select record_sale(
  '[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20},
    {"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":0,"price_reason":"Staff"}]'::jsonb,
  null, '[{"method":"cash","amount":21.65}]'::jsonb, null) as id;
create temp table lines as
select (select sl.id from sale_lines sl where sl.sale_id = (select id from free_sale)) as free_line,
       (select sl.id from sale_lines sl where sl.sale_id = (select id from mixed_sale) and sl.unit_price = 0) as gift_line;
grant select on free_sale, mixed_sale, lines to authenticated;

select is((select coalesce(sum(qty), 0) from inventory_txns where product_id = '00000000-0000-0000-0000-0000000000b1'),
          6.000, '4 of the 10 strings left in the two sales');

-- ---------------------------------------------------------------------------
-- A $0 sale
-- ---------------------------------------------------------------------------
select throws_like(
  format($$ select record_refund('%s', '[{"sale_line_id":"%s","qty":1}]'::jsonb,
                                 '[{"method":"cash","amount":0}]'::jsonb, null, null, null) $$,
         (select id from free_sale), (select free_line from lines)),
  'Refund amount must be positive', 'a $0 refund payment is refused');
select lives_ok(
  format($$ select record_refund('%s', '[{"sale_line_id":"%s","qty":2}]'::jsonb, '[]'::jsonb, null, null, null) $$,
         (select id from free_sale), (select free_line from lines)),
  'a $0 sale can be returned with no payments and no reason');
select results_eq(
  format($$ select subtotal, tax from refunds where sale_id = '%s' $$, (select id from free_sale)),
  $$ values (0.00::numeric(12,2), 0.00::numeric(12,2)) $$,
  'the refund is for $0');
select is((select count(*)::int from refund_payments rp join refunds r on r.id = rp.refund_id
            where r.sale_id = (select id from free_sale)),
          0, 'with no refund payments');
select is((select coalesce(sum(qty), 0) from inventory_txns where product_id = '00000000-0000-0000-0000-0000000000b1'),
          8.000, 'both strings go back in stock');
select throws_like(
  format($$ select record_refund('%s', '[{"sale_line_id":"%s","qty":1}]'::jsonb, '[]'::jsonb, null, null, null) $$,
         (select id from free_sale), (select free_line from lines)),
  'Cannot return 1 of line (only 0 remaining)', 'they can''t be returned twice');

-- ---------------------------------------------------------------------------
-- A free item on a paid sale
-- ---------------------------------------------------------------------------
select lives_ok(
  format($$ select record_refund('%s', '[{"sale_line_id":"%s","qty":1}]'::jsonb, '[]'::jsonb, null, null, null) $$,
         (select id from mixed_sale), (select gift_line from lines)),
  'the free item on a paid sale can be returned on its own, with no payments');
select is((select coalesce(sum(qty), 0) from inventory_txns where product_id = '00000000-0000-0000-0000-0000000000b1'),
          9.000, 'and goes back in stock');

-- The report: 4 items sold, 3 returned; no money refunded.
select results_eq(
  $$ select num_items, refunds from sales_summary(now() - interval '1 hour', now() + interval '1 hour') $$,
  $$ values (1, 0.00::numeric) $$,
  'the sales report counts the returned items and no money refunded');

select * from finish();
rollback;
