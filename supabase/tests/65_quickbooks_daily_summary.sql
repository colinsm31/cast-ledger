-- The daily summary for QuickBooks (0101).
begin;
\ir helpers/setup.psql
\ir helpers/report_sales.psql

select plan(9);

-- One more sale, at 9 PM on 12 Nov in Chicago (3 AM on 13 Nov UTC): an
-- overgrip paid by gift card.
insert into sales (id, sold_at, subtotal, tax, tax_rate, payment_method) values
  ('00000000-0000-0000-0000-0000000005c4', '2026-11-13 03:00Z', 10, 0, 0, 'gift_card');
insert into sale_lines (sale_id, product_id, qty, unit_price) values
  ('00000000-0000-0000-0000-0000000005c4', '00000000-0000-0000-0000-0000000000b3', 1, 10);
insert into sale_payments (sale_id, method, amount, gift_card_id) values
  ('00000000-0000-0000-0000-0000000005c4', 'gift_card', 10, '00000000-0000-0000-0000-0000000006c1');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select * from report_daily_summary('2026-11-01Z', '2026-12-01Z', 'America/Chicago') $$, '42501',
                 'Only an admin can see reports', 'staff can''t export the daily summary');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok($$ select * from report_daily_summary('2026-11-01Z', '2026-12-01Z', 'Mars/Olympus') $$, '22023',
                 'Unknown time zone: Mars/Olympus', 'an unknown time zone is refused');

-- 10 Nov: the cash sale.
select results_eq(
  $$ select account, debit, credit, memo from report_daily_summary('2026-11-01Z', '2026-12-01Z', 'America/Chicago')
      where day = '2026-11-10' order by line_no $$,
  $$ values ('Undeposited Funds'::text, 54.13::numeric, null::numeric, 'Cash'::text),
            ('Sales', null, 10.00, 'Sales: pgTAP Strings'),
            ('Sales', null, 40.00, 'Sales: Strings'),
            ('Sales Tax Payable', null, 4.13, 'Sales tax') $$,
  'a day''s takings as debits; sales by category and tax as credits');

-- 11 Nov: card payment for stringing and a gift card load.
select results_eq(
  $$ select account, debit, credit, memo from report_daily_summary('2026-11-01Z', '2026-12-01Z', 'America/Chicago')
      where day = '2026-11-11' order by line_no $$,
  $$ values ('Undeposited Funds'::text, 55.00::numeric, null::numeric, 'Card'::text),
            ('Stringing Income', null, 30.00, 'Stringing'),
            ('Gift Card Liability', null, 25.00, 'Gift cards sold') $$,
  'stringing is its own income; a gift card sold is a liability, not a sale');

-- 12 Nov (Chicago): the refund nets against the late gift card sale.
select results_eq(
  $$ select account, debit, credit, memo from report_daily_summary('2026-11-01Z', '2026-12-01Z', 'America/Chicago')
      where day = '2026-11-12' order by line_no $$,
  $$ values ('Undeposited Funds'::text, null::numeric, 21.65::numeric, 'Cash'::text),
            ('Gift Card Liability', 10.00, null, 'Paid by gift card'),
            ('Sales', null, 10.00, 'Sales: pgTAP Strings'),
            ('Sales', 20.00, null, 'Sales: Strings'),
            ('Sales Tax Payable', 1.65, null, 'Sales tax') $$,
  'a refund moves to the other column; days follow the shop''s time zone');

select is((select count(*)::int from report_daily_summary('2026-11-01Z', '2026-12-01Z', 'UTC') where day = '2026-11-13'), 2,
          'in UTC the late sale falls on the 13th');

select is(
  (select count(*)::int from (
     select day from report_daily_summary('2026-11-01Z', '2026-12-01Z', 'America/Chicago')
      group by day having sum(coalesce(debit, 0)) <> sum(coalesce(credit, 0))) unbalanced),
  0, 'every day''s debits equal its credits');

-- Account names come from Settings.
select tests.clear_authentication();
update settings set qb_cash_account = 'Cash Drawer' where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select is((select account from report_daily_summary('2026-11-01Z', '2026-12-01Z', 'America/Chicago')
            where day = '2026-11-10' and line_no = 1), 'Cash Drawer', 'the account names are the shop''s');
select tests.clear_authentication();

select throws_ok($$ update settings set qb_sales_account = '  ' where id $$, '23514', null,
                 'an account name can''t be blank');

select * from finish();
rollback;
