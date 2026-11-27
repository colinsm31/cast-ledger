-- The daily (X / Z) report (0111).
begin;
\ir helpers/setup.psql
\ir helpers/report_sales.psql

select plan(12);

update settings set time_zone = 'America/Chicago' where id;

-- A drawer opened on 10 Nov that took S1's cash, closed $4.13 short, with a
-- $5 paid-out; another opened on 11 Nov and still open.
insert into drawer_sessions (id, drawer_id, business_day, opened_at, float_counts, float_amount,
                             closed_at, counted_counts, counted_cash, expected_cash) values
  ('00000000-0000-0000-0000-0000000009e1', (select id from drawers where name = 'Main drawer'), '2026-11-10',
   '2026-11-10 14:00Z', '{"20": 5}', 100, '2026-11-10 23:00Z', '{"50": 3}', 145, 149.13);
insert into drawer_movements (drawer_session_id, kind, amount, reason) values
  ('00000000-0000-0000-0000-0000000009e1', 'paid_out', 5, 'Stamps');
update sales set drawer_session_id = '00000000-0000-0000-0000-0000000009e1'
 where id = '00000000-0000-0000-0000-0000000005c1';
insert into drawers (id, name) values ('00000000-0000-0000-0000-0000000009d2', 'Back counter');
insert into drawer_sessions (drawer_id, business_day, opened_at, float_counts, float_amount) values
  ('00000000-0000-0000-0000-0000000009d2', '2026-11-11', '2026-11-11 14:00Z', '{"20": 2}', 40);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- 10 Nov: the cash sale.
select is(report_day('2026-11-10') -> 'sales',
          '{"count": 1, "items": 50.00, "gift_cards": 0, "tax": 4.13}'::jsonb,
          'sales: count, items, gift cards and tax');
select is(report_day('2026-11-10') -> 'payments',
          '[{"method": "cash", "label": "Cash", "taken": 54.13, "given_back": 0, "net": 54.13}]'::jsonb,
          'totals by payment type list only the types used');
select is(report_day('2026-11-10') -> 'categories',
          '[{"name": "pgTAP Strings", "sold": 10.00, "returned": 0, "net": 10.00},
            {"name": "Strings", "sold": 40.00, "returned": 0, "net": 40.00}]'::jsonb,
          'sales by category');
select is((report_day('2026-11-10') -> 'drawers' -> 0) - 'opened_at' - 'closed_at',
          '{"drawer": "Main drawer", "float": 100.00, "cash_sales": 54.13, "cash_refunds": 0, "paid_in": 0,
            "paid_out": 5.00, "expected": 149.13, "counted": 145.00, "over_short": -4.13}'::jsonb,
          'each drawer with its float, cash in and out, expected, counted and over/short');

-- 11 Nov: card for stringing and a gift card; a drawer still open.
select is(report_day('2026-11-11') -> 'sales',
          '{"count": 1, "items": 30.00, "gift_cards": 25.00, "tax": 0}'::jsonb,
          'gift cards sold are apart from items');
select is(report_day('2026-11-11') -> 'categories' -> 0 ->> 'name', 'Stringing', 'stringing is its own line');
select is((report_day('2026-11-11') -> 'drawers' -> 0) - 'opened_at' - 'closed_at',
          '{"drawer": "Back counter", "float": 40.00, "cash_sales": 0, "cash_refunds": 0, "paid_in": 0,
            "paid_out": 0, "expected": 40.00, "counted": null, "over_short": null}'::jsonb,
          'an open drawer shows what it should hold now, and no count yet');

-- 12 Nov: the cash refund.
select is(report_day('2026-11-12') -> 'refunds',
          '{"count": 1, "items": 20.00, "gift_cards": 0, "tax": 1.65}'::jsonb,
          'refunds: count, items and tax given back');
select is(report_day('2026-11-12') -> 'payments' -> 0,
          '{"method": "cash", "label": "Cash", "taken": 0, "given_back": 21.65, "net": -21.65}'::jsonb,
          'money given back counts against its payment type');
select is(report_day('2026-11-12') -> 'exchanges', '{"count": 0, "credit": 0}'::jsonb, 'no exchanges that day');

-- Checks ------------------------------------------------------------------------
select throws_ok($$ select report_day(null) $$, '22023', 'Choose a day', 'a day is needed');
select tests.clear_authentication();
update settings set time_zone = null where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select report_day('2026-11-10') $$, '22023',
                 'An admin needs to set the shop''s time zone in Settings first',
                 'the report needs the shop''s time zone');

select * from finish();
rollback;
