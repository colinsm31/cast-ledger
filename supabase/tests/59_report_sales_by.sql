-- Sales by category, brand, product and staff, with margin (0095).
begin;
\ir helpers/setup.psql
\ir helpers/report_sales.psql

select plan(12);

-- ---------------------------------------------------------------------------
-- Only admins, for a real period, by a known grouping
-- ---------------------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  $$ select * from report_sales_by('2026-11-01Z', '2026-12-01Z', 'category') $$,
  '42501', 'Only an admin can see reports', 'staff can''t run a report');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(
  $$ select * from report_sales_by('2026-12-01Z', '2026-11-01Z', 'category') $$,
  '22023', 'A report needs a start before its end', 'a period must start before it ends');
select throws_ok(
  $$ select * from report_sales_by('2026-11-01Z', null, 'category') $$,
  '22023', 'A report needs a start before its end', 'and have an end');
select throws_ok(
  $$ select * from report_sales_by('2026-11-01Z', '2026-12-01Z', 'colour') $$,
  '22023', 'A sales report is by category, brand, product or staff, not colour', 'an unknown grouping is refused');

-- ---------------------------------------------------------------------------
-- By category: the string's category nets one string after the return; the
-- overgrip has no cost; stringing is its own row; the gift card load and the
-- October sale aren't counted.
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select label, tickets, qty_sold, sales, discounts, qty_returned, returns, net_qty, net_sales,
            costed_sales, cost, margin, margin_pct, uncosted_qty, cost_estimated
       from report_sales_by('2026-11-01Z', '2026-12-01Z', 'category') $$,
  $$ values ('Stringing'::text, 1, 1, 30.00::numeric, 0.00::numeric, 0, 0::numeric, 1, 30.00::numeric,
             0::numeric, 0::numeric, null::numeric, null::numeric, 0, false),
            ('Strings', 1, 2, 40.00, 10.00, 1, 20.00, 1, 20.00, 20.00, 8.00, 12.00, 60.0, 0, false),
            ('pgTAP Strings', 1, 1, 10.00, 0.00, 0, 0, 1, 10.00, 0, 0, null, null, 1, false) $$,
  'by category: sales less returns, margin only on items with a cost');

select results_eq(
  $$ select label, net_sales from report_sales_by('2026-11-01Z', '2026-12-01Z', 'brand') $$,
  $$ values ('Stringing'::text, 30.00::numeric), ('TestBrand', 20.00), ('Zeta', 10.00) $$,
  'by brand');

select results_eq(
  $$ select label, detail, net_qty from report_sales_by('2026-11-01Z', '2026-12-01Z', 'product') $$,
  $$ values ('Stringing'::text, null::text, 1), ('TestBrand Test String 16', 'Strings', 1), ('Zeta Overgrip', 'pgTAP Strings', 1) $$,
  'by product, with each product''s category');

-- The return comes off the staff member who rang the sale, not who refunded it.
select results_eq(
  $$ select label, tickets, sales, returns, net_sales from report_sales_by('2026-11-01Z', '2026-12-01Z', 'staff') $$,
  $$ values ('admin@test.local'::text, 1, 30.00::numeric, 0::numeric, 30.00::numeric),
            ('staff@test.local', 1, 50.00, 20.00, 30.00) $$,
  'by staff: each sale and its returns go to who rang it');

-- A return in a later period counts in that period, against the original line.
select results_eq(
  $$ select label, qty_sold, qty_returned, net_qty, returns, cost from report_sales_by('2026-11-12Z', '2026-11-13Z', 'product') $$,
  $$ values ('TestBrand Test String 16'::text, 0, 1, -1, 20.00::numeric, -8.00::numeric) $$,
  'a return on its own day is a negative line, at the cost it was sold at');

-- A product with a backfilled cost is marked estimated.
select tests.clear_authentication();
update sale_lines set unit_cost_estimated = true where id = '00000000-0000-0000-0000-0000000007c5';
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select results_eq(
  $$ select label, margin, cost_estimated from report_sales_by('2026-10-01Z', '2026-10-02Z', 'category') $$,
  $$ values ('Strings'::text, 60.00::numeric, true) $$,
  'a margin using a backfilled cost is marked estimated');

select is((select count(*)::int from report_sales_by('2025-01-01Z', '2025-02-01Z', 'staff')), 0,
          'a period with no sales has no rows');

-- An unrecorded staff member still shows.
select tests.clear_authentication();
update sales set user_id = null where id = '00000000-0000-0000-0000-0000000005c3';
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select results_eq(
  $$ select group_key, label from report_sales_by('2026-10-01Z', '2026-10-02Z', 'staff') $$,
  $$ values (''::text, '(not recorded)'::text) $$,
  'a sale with nobody recorded is under "(not recorded)"');

select * from finish();
rollback;
