-- Cash paid into or out of a drawer outside a sale (0110).
begin;
\ir helpers/setup.psql

select plan(14);

update settings set time_zone = 'America/Chicago', cash_needs_drawer = true where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select open_drawer((select id from drawers where name = 'Main drawer'), '{"20": 5}');
select record_sale('[{"product_id":"00000000-0000-0000-0000-0000000000b1","qty":1,"unit_price":20}]', null,
                   '[{"method":"cash","amount":21.65}]', null);

select lives_ok($$ select record_drawer_movement((select id from drawer_sessions), 'paid_in', 25, 'Change from the bank') $$,
                'staff record a paid-in with a reason');
select lives_ok($$ select record_drawer_movement((select id from drawer_sessions), 'paid_out', 6.50, '  ') $$,
                'and a paid-out with no reason');
select results_eq(
  $$ select kind, amount, reason, user_id from drawer_movements order by created_at, kind $$,
  $$ values ('paid_in'::text, 25.00::numeric, 'Change from the bank'::text, '00000000-0000-0000-0000-0000000000a1'::uuid),
            ('paid_out', 6.50, null, '00000000-0000-0000-0000-0000000000a1') $$,
  'each is recorded with who made it; a blank reason is left off');
select results_eq(
  $$ select paid_in, paid_out, expected_cash from drawer_cash_summary((select id from drawer_sessions)) $$,
  $$ values (25.00::numeric, 6.50::numeric, 140.15::numeric) $$,
  'expected cash adds paid-ins and takes off paid-outs');

select throws_ok($$ select record_drawer_movement((select id from drawer_sessions), 'paid_out', 140.16) $$, '22023',
                 'The drawer should only hold $140.15', 'a paid-out can''t take more than the drawer holds');
select throws_ok($$ select record_drawer_movement((select id from drawer_sessions), 'bonus', 1) $$, '22023',
                 'Choose paid in or paid out', 'only paid in or out');
select throws_ok($$ select record_drawer_movement((select id from drawer_sessions), 'paid_in', 0) $$, '22023',
                 'Enter an amount over $0', 'an amount over $0');
select throws_ok($$ select record_drawer_movement((select id from drawer_sessions), 'paid_in', 1.005) $$, '22023',
                 'Use at most 2 decimal places', 'whole cents');
select throws_ok($$ select record_drawer_movement((select id from drawer_sessions), 'paid_in', 1, repeat('x', 201)) $$, '22023',
                 'Keep the reason to 200 characters', 'a reason is at most 200 characters');
select throws_ok($$ select record_drawer_movement('00000000-0000-0000-0000-00000000dead', 'paid_in', 1) $$, 'P0002',
                 'Drawer session not found', 'an unknown drawer session is refused');
select throws_ok($$ insert into drawer_movements (drawer_session_id, kind, amount) values ((select id from drawer_sessions), 'paid_in', 1) $$,
                 '42501', null, 'movements are written only through record_drawer_movement');
select throws_ok($$ delete from drawer_movements $$, '42501', null, 'and never deleted');

select close_drawer((select id from drawer_sessions), '{"20": 7}');
select is((select expected_cash from drawer_sessions), 140.15::numeric, 'the close saves expected cash with them');
select throws_ok($$ select record_drawer_movement((select id from drawer_sessions), 'paid_in', 1) $$, '22023',
                 'This drawer has been closed', 'a closed drawer takes no paid-ins');

select * from finish();
rollback;
