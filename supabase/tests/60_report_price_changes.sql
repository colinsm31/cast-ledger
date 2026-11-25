-- Discounts and price changes by who made and approved them (0096).
begin;
\ir helpers/setup.psql
\ir helpers/report_sales.psql

select plan(5);

-- The stringing charge on S2 took $3 of the admin-approved ticket discount.
update sale_lines set price_before_discount = 33, ticket_discount_each = 3
 where id = '00000000-0000-0000-0000-0000000007c3';

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  $$ select * from report_price_changes('2026-11-01Z', '2026-12-01Z') $$,
  '42501', 'Only an admin can see reports', 'staff can''t see who gave discounts');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(
  $$ select * from report_price_changes('2026-11-02Z', '2026-11-01Z') $$,
  '22023', 'A report needs a start before its end', 'a period must start before it ends');

select results_eq(
  $$ select kind, made_by, approved_by, item, qty, from_price, to_price, amount, reason
       from report_price_changes('2026-11-01Z', '2026-12-01Z') $$,
  $$ values
       ('line_discount'::text, 'staff@test.local'::text, null::text, 'TestBrand Test String 16'::text, 2,
        25.00::numeric, 20.00::numeric, 10.00::numeric, '(none)'::text),
       ('price_change', 'staff@test.local', null, 'Zeta Overgrip', 1, 12.00, 10.00, 2.00, 'Scuffed'),
       ('ticket_discount', 'admin@test.local', 'admin@test.local', 'Stringing', 1, 33.00, 30.00, 3.00, 'Loyal customer') $$,
  'each change with who rang it, who approved it, and the reason or "(none)"');

-- A raised price is a negative amount; a line discount and a ticket discount
-- on one line are two rows; the October sale isn't in November.
select tests.clear_authentication();
update sale_lines set list_price = 18, price_before_discount = 22, line_discount_each = 1, ticket_discount_each = 1
 where id = '00000000-0000-0000-0000-0000000007c5';
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select results_eq(
  $$ select kind, from_price, to_price, amount, reason from report_price_changes('2026-10-01Z', '2026-10-02Z') $$,
  $$ values ('price_change'::text, 18.00::numeric, 22.00::numeric, -20.00::numeric, '(none)'::text),
            ('line_discount', 22.00, 21.00, 5.00, '(none)'),
            ('ticket_discount', 21.00, 20.00, 5.00, '(none)') $$,
  'a raise is negative, and a line and ticket discount on one line are two rows');

select is((select count(*)::int from report_price_changes('2025-01-01Z', '2025-02-01Z')), 0,
          'a period with no sales has no rows');

select * from finish();
rollback;
