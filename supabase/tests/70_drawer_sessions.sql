-- Cash drawers opened with a float and closed with a count (0108).
begin;
\ir helpers/setup.psql

select plan(25);

-- The shop's time zone ----------------------------------------------------------
select throws_ok($$ update settings set time_zone = 'Mars/Olympus' where id $$, '22023',
                 'Unknown time zone: Mars/Olympus', 'an unknown time zone is refused');
select lives_ok($$ update settings set time_zone = 'America/Chicago' where id $$, 'a real time zone is saved');
select is(shop_day('2026-11-13 03:00Z'), '2026-11-12'::date, 'business days follow the shop''s time zone');
-- Clearing the time zone is refused (0115); the trigger is set aside to test no time zone.
alter table settings disable trigger trg_settings_time_zone;
update settings set time_zone = null where id;
alter table settings enable trigger trg_settings_time_zone;
select throws_ok($$ select shop_day(now()) $$, '22023',
                 'An admin needs to set the shop''s time zone in Settings first',
                 'with no time zone set, there is no business day');

-- Counting by denomination ------------------------------------------------------
select is(drawer_count_total('{"20": 3, "5": 2, "1": 4, "0.25": 3, "0.01": 2, "other": 10.50}'), 85.27::numeric,
          'a count adds up its bills, coins and other cash');
select is(drawer_count_total('{}'), 0::numeric, 'an empty count is $0');
select throws_ok($$ select drawer_count_total('{"3": 1}') $$, '22023', 'Unknown denomination: 3',
                 'an unknown denomination is refused');
select throws_ok($$ select drawer_count_total('{"20": 1.5}') $$, '22023', 'Count whole bills and coins',
                 'part of a bill is refused');
select throws_ok($$ select drawer_count_total('{"20": -1}') $$, '22023', 'Each count must be a number of 0 or more',
                 'a negative count is refused');
select throws_ok($$ select drawer_count_total('{"other": 1.005}') $$, '22023', 'Other cash must be in dollars and cents',
                 'other cash is in cents');
select throws_ok($$ select drawer_count_total('[]') $$, '22023', 'Count the drawer by denomination',
                 'a count is an object of denominations');

-- Drawers -----------------------------------------------------------------------
select is((select array_agg(name) from drawers), array['Main drawer'], 'the shop starts with one drawer');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ insert into drawers (name) values ('Back counter') $$, '42501', null,
                 'staff can''t add a drawer');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select lives_ok($$ insert into drawers (id, name) values ('00000000-0000-0000-0000-0000000009d2', 'Back counter') $$,
                'an admin adds a drawer');
select throws_ok($$ insert into drawers (name) values (' back COUNTER ') $$, '23505', null,
                 'drawer names are unique, ignoring case and spaces');

-- Opening and closing -----------------------------------------------------------
select tests.clear_authentication();
update settings set time_zone = 'America/Chicago' where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

select lives_ok($$ select open_drawer((select id from drawers where name = 'Main drawer'), '{"20": 5, "1": 10}') $$,
                'staff open a drawer with a float');
select results_eq(
  $$ select float_amount, business_day = (now() at time zone 'America/Chicago')::date, opened_by
       from drawer_sessions $$,
  $$ values (110.00::numeric, true, '00000000-0000-0000-0000-0000000000a1'::uuid) $$,
  'the float, business day and who opened it are recorded');
select throws_ok($$ select open_drawer((select id from drawers where name = 'Main drawer'), '{}') $$, '23505',
                 'Main drawer is already open', 'a drawer opens once at a time');
select throws_ok($$ insert into drawer_sessions (drawer_id, business_day, float_counts, float_amount)
                    values ('00000000-0000-0000-0000-0000000009d2', current_date, '{}', 0) $$, '42501', null,
                 'sessions change only through the drawer functions');

select throws_ok($$ select open_drawer('00000000-0000-0000-0000-00000000dead', '{}') $$, 'P0002', 'Drawer not found',
                 'an unknown drawer can''t be opened');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
update drawers set is_active = false where id = '00000000-0000-0000-0000-0000000009d2';
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select open_drawer('00000000-0000-0000-0000-0000000009d2', '{}') $$, '22023',
                 'Back counter isn''t in use', 'a drawer taken out of use can''t be opened');
select throws_ok($$ select close_drawer('00000000-0000-0000-0000-00000000dead', '{}') $$, 'P0002',
                 'Drawer session not found', 'an unknown session can''t be closed');

select lives_ok($$ select close_drawer((select id from drawer_sessions), '{"20": 6, "1": 12, "other": 0.50}', '  ') $$,
                'staff close the drawer with a count');
select results_eq($$ select counted_cash, closed_by, close_note, closed_at is not null from drawer_sessions $$,
                  $$ values (132.50::numeric, '00000000-0000-0000-0000-0000000000a1'::uuid, null::text, true) $$,
                  'the count, who closed it and when are recorded; a blank note is left off');
select throws_ok($$ select close_drawer((select id from drawer_sessions), '{}') $$, '22023',
                 'This drawer has already been closed', 'a drawer closes once');

select * from finish();
rollback;
