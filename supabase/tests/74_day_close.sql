-- Closing a business day, and keeping it closed (0112).
begin;
\ir helpers/setup.psql

select plan(24);

update settings set time_zone = 'America/Chicago' where id;
create function tests.today() returns date language sql as $$ select (now() at time zone 'America/Chicago')::date $$;
grant execute on function tests.today() to authenticated;
insert into gift_cards (id, code) values ('00000000-0000-0000-0000-0000000006c9', 'GCCLOSE');
insert into gift_card_txns (gift_card_id, amount, reason) values ('00000000-0000-0000-0000-0000000006c9', 10, 'load');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select open_drawer((select id from drawers where name = 'Main drawer'), '{"20": 5}');
select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]', null,
                   '[{"method":"cash","amount":21.65}]', null);

-- Closing ------------------------------------------------------------------------
select throws_ok($$ select close_day(tests.today()) $$, '22023',
                 'Count and close every drawer first (still open: Main drawer)',
                 'a day closes only once every drawer is closed');
select throws_ok($$ select close_day(tests.today() + 1) $$, '22023',
                 'A day can''t be closed before it has started', 'tomorrow can''t be closed');
select throws_ok($$ select close_day(null) $$, '22023', 'Choose a day', 'a day is needed');
select close_drawer((select id from drawer_sessions), '{"20": 6, "1": 1, "0.25": 2, "0.10": 1, "0.05": 1}');
select lives_ok($$ select close_day(tests.today()) $$, 'staff close the day once the drawers are closed');
select results_eq(
  $$ select closed_by, report -> 'sales' ->> 'count', report -> 'drawers' -> 0 ->> 'over_short' from day_closes $$,
  $$ values ('00000000-0000-0000-0000-0000000000a1'::uuid, '1'::text, '0.00'::text) $$,
  'the close saves who closed it and the day''s report as it stood');
select throws_ok($$ select close_day(tests.today()) $$, '22023', 'That day is already closed', 'a day closes once');
select ok(is_day_closed(tests.today()), 'the day is closed');

-- What a closed day blocks ---------------------------------------------------------
select throws_like(
  $$ select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]', null,
                        '[{"method":"credit","amount":21.65}]', null) $$,
  'That business day (%) has been closed. An admin can reopen it on the End of Day screen',
  'no new sales on a closed day');
select throws_like(
  $$ select record_refund((select id from sales),
                          (select jsonb_build_array(jsonb_build_object('sale_line_id', id, 'qty', 1)) from sale_lines),
                          '[{"method":"credit","amount":21.65}]', null, null) $$,
  'That business day (%) has been closed%', 'no refunds');
select throws_like($$ select adjust_gift_card('00000000-0000-0000-0000-0000000006c9', -1, null) $$,
                   'That business day (%) has been closed%', 'no gift card changes');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select throws_like($$ select add_store_credit('00000000-0000-0000-0000-0000000000c1', 5, null) $$,
                   'That business day (%) has been closed%', 'no store credit changes, even by an admin');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like($$ select open_drawer((select id from drawers where name = 'Main drawer'), '{}') $$,
                   'That business day (%) has been closed%', 'no drawer opened');
select lives_ok($$ select adjust_stock('00000000-0000-0000-0000-0000000000b1', -1, 'Damaged') $$,
                'stock can still be adjusted');
select lives_ok($$ insert into customers (first_name, last_name) values ('After', 'Hours') $$,
                'and customers added');

-- A sale from a closed day can be refunded on a later day.
select tests.clear_authentication();
insert into sales (id, sold_at, subtotal, tax, tax_rate, payment_method) values
  ('00000000-0000-0000-0000-0000000005d1', now() - interval '3 days', 20, 1.65, 8.25, 'credit');
insert into sale_lines (id, sale_id, product_id, qty, unit_price) values
  ('00000000-0000-0000-0000-0000000007d1', '00000000-0000-0000-0000-0000000005d1', '00000000-0000-0000-0000-0000000000b1', 1, 20);
insert into sale_payments (sale_id, method, amount) values ('00000000-0000-0000-0000-0000000005d1', 'credit', 21.65);
insert into day_closes (business_day, report) values (tests.today() - 3, '{}');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like($$ select record_refund('00000000-0000-0000-0000-0000000005d1',
                                           '[{"sale_line_id":"00000000-0000-0000-0000-0000000007d1","qty":1}]',
                                           '[{"method":"credit","amount":21.65}]', null, null) $$,
                   'That business day (%) has been closed%',
                   '(today is closed too, so a refund today is refused)');

-- Reopening ----------------------------------------------------------------------
select throws_ok($$ select reopen_day(tests.today(), 'Forgot a sale') $$, '42501',
                 'Only an admin can reopen a closed day', 'staff can''t reopen a day');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok($$ select reopen_day(tests.today() + 5) $$, '22023', 'That day isn''t closed',
                 'only a closed day can be reopened');
select throws_ok($$ select reopen_day(tests.today(), repeat('x', 501)) $$, '22023',
                 'Keep the reason to 500 characters', 'a reason is at most 500 characters');
select lives_ok($$ select reopen_day(tests.today(), '  ') $$, 'an admin reopens the day, with no reason');
select results_eq(
  $$ select reopened_by, reopen_reason from day_closes where business_day = tests.today() $$,
  $$ values ('00000000-0000-0000-0000-0000000000a2'::uuid, null::text) $$,
  'the close is kept, marked reopened by the admin');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok($$ select record_refund('00000000-0000-0000-0000-0000000005d1',
                                        '[{"sale_line_id":"00000000-0000-0000-0000-0000000007d1","qty":1}]',
                                        '[{"method":"credit","amount":21.65}]', null, null) $$,
                'with today reopened, a sale from a closed day is refunded today');
select lives_ok($$ select close_day(tests.today()) $$, 'the day closes again');
select is((select count(*)::int from day_closes where business_day = tests.today()), 2,
          'each close is kept');

select throws_ok($$ insert into day_closes (business_day, report) values ('2026-01-01', '{}') $$, '42501', null,
                 'closes are written only through close_day');

select * from finish();
rollback;
