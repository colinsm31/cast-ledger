-- Gift card and store credit liability at a moment (0098).
begin;
\ir helpers/setup.psql

select plan(5);

insert into customers (id, first_name, last_name) values
  ('00000000-0000-0000-0000-0000000000c2', 'Ann', 'Able');
insert into gift_cards (id, code, customer_id, is_active) values
  ('00000000-0000-0000-0000-0000000006d1', 'GC-OWED', '00000000-0000-0000-0000-0000000000c1', true),
  ('00000000-0000-0000-0000-0000000006d2', 'GC-SPENT', null, true),
  ('00000000-0000-0000-0000-0000000006d3', 'GC-OFF', null, true);
insert into gift_card_txns (gift_card_id, amount, reason, created_at) values
  ('00000000-0000-0000-0000-0000000006d1', 50, 'load', '2026-11-01 10:00Z'),
  ('00000000-0000-0000-0000-0000000006d1', -20, 'redeem', '2026-11-15 10:00Z'),
  ('00000000-0000-0000-0000-0000000006d2', 25, 'load', '2026-11-01 10:00Z'),
  ('00000000-0000-0000-0000-0000000006d2', -25, 'redeem', '2026-11-02 10:00Z'),
  ('00000000-0000-0000-0000-0000000006d3', 10, 'load', '2026-11-03 10:00Z');
insert into store_credit_txns (customer_id, amount, reason, created_at) values
  ('00000000-0000-0000-0000-0000000000c2', 15, 'refund', '2026-11-05 10:00Z');

-- GC-OFF is made inactive with value still on it.
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select set_gift_card_active('00000000-0000-0000-0000-0000000006d3', false, null);
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select * from report_balances(now()) $$, '42501', 'Only an admin can see reports',
                 'staff can''t see the liability report');
select tests.clear_authentication();

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok($$ select * from report_balances(null) $$, '22023', 'Choose the moment to report balances at',
                 'a moment is needed');

select results_eq(
  $$ select kind, code, customer, balance, last_activity, is_active from report_balances('2026-12-01Z') $$,
  $$ values ('gift_card'::text, 'GC-OWED'::text, 'Tester, Pat'::text, 30.00::numeric, '2026-11-15 10:00Z'::timestamptz, true),
            ('gift_card', 'GC-OFF', null, 10.00, '2026-11-03 10:00Z', false),
            ('store_credit', null, 'Able, Ann', 15.00, '2026-11-05 10:00Z', true) $$,
  'what''s owed now: spent cards left out, an inactive card still listed');

select results_eq(
  $$ select code, balance from report_balances('2026-11-10Z') where kind = 'gift_card' $$,
  $$ values ('GC-OWED'::text, 50.00::numeric), ('GC-OFF', 10.00) $$,
  'an earlier moment counts only the history before it');

select is((select count(*)::int from report_balances('2026-10-01Z')), 0, 'nothing owed before any card was loaded');

select * from finish();
rollback;
