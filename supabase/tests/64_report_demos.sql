-- Demo program activity (0100).
begin;
\ir helpers/setup.psql

select plan(4);

-- Three demo frames of the test racquet and one of a second model.
insert into products (id, category_id, brand, name, sell_price, cost) values
  ('00000000-0000-0000-0000-0000000000b7', '00000000-0000-0000-0000-0000000000d2', 'Zeta', 'Speed 98', 230.00, 140.00);
insert into product_units (id, product_id, barcode, status) values
  ('00000000-0000-0000-0000-000000000ad1', '00000000-0000-0000-0000-0000000000b2', 'DEMO-1', 'demo'),
  ('00000000-0000-0000-0000-000000000ad2', '00000000-0000-0000-0000-0000000000b2', 'DEMO-2', 'demo'),
  ('00000000-0000-0000-0000-000000000ad3', '00000000-0000-0000-0000-0000000000b2', 'DEMO-3', 'demo'),
  ('00000000-0000-0000-0000-000000000ad4', '00000000-0000-0000-0000-0000000000b7', 'DEMO-4', 'demo');
insert into sales (id, sold_at, subtotal, tax, tax_rate) values
  ('00000000-0000-0000-0000-0000000005d1', '2026-11-06 12:00Z', 250, 0, 0);

-- November, test racquet:
--   1: out 2 Nov, back 4 Nov (2 days), led to a sale
--   2: out 3 Nov, back 7 Nov (4 days), retired on return
--   3: out 20 Nov, due back long ago, still out (overdue)
-- Second model: out in October, back 1 Nov (1 day).
insert into demo_loans (product_unit_id, customer_id, out_at, due_back_at, back_at, back_status, sale_id) values
  ('00000000-0000-0000-0000-000000000ad1', '00000000-0000-0000-0000-0000000000c1', '2026-11-02 10:00Z', '2026-11-05 10:00Z',
   '2026-11-04 10:00Z', 'demo', '00000000-0000-0000-0000-0000000005d1'),
  ('00000000-0000-0000-0000-000000000ad2', '00000000-0000-0000-0000-0000000000c1', '2026-11-03 10:00Z', '2026-11-06 10:00Z',
   '2026-11-07 10:00Z', 'retired', null),
  ('00000000-0000-0000-0000-000000000ad3', '00000000-0000-0000-0000-0000000000c1', '2026-11-20 10:00Z', '2026-11-21 10:00Z',
   null, null, null),
  ('00000000-0000-0000-0000-000000000ad4', '00000000-0000-0000-0000-0000000000c1', '2026-10-31 10:00Z', '2026-11-03 10:00Z',
   '2026-11-01 10:00Z', 'demo', null);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select * from report_demos('2026-11-01Z', '2026-12-01Z') $$, '42501',
                 'Only an admin can see reports', 'staff can''t see the demo report');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select results_eq(
  $$ select racquet, loans, led_to_sale, conversion_pct, returned, retired, avg_days_out, out_now, overdue_now
       from report_demos('2026-11-01Z', '2026-12-01Z') $$,
  $$ values ('TestBrand Test Racquet 100'::text, 3, 1, 33.3::numeric, 2, 1, 3.0::numeric, 1, 1),
            ('Zeta Speed 98', 0, 0, null, 1, 0, 1.0, 0, 0) $$,
  'loans, sales they led to, returns, retirements, days out, and what''s out and overdue now');

select results_eq(
  $$ select racquet, loans, returned, out_now from report_demos('2026-10-01Z', '2026-11-01Z') $$,
  $$ values ('Zeta Speed 98'::text, 1, 0, 0), ('TestBrand Test Racquet 100', 0, 0, 1) $$,
  'October: one loan; what''s out now still shows');

select throws_ok($$ select * from report_demos('2026-11-01Z', '2026-11-01Z') $$, '22023',
                 'A report needs a start before its end', 'a period must have some length');

select * from finish();
rollback;
