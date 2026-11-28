-- Daily report totals on the server, and plain messages (0116).
begin;
\ir helpers/setup.psql
\ir helpers/report_sales.psql

select plan(5);

update settings set time_zone = 'America/Chicago' where id;
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- 10 Nov: S1, $54.13 taken; 12 Nov: only R1, $21.65 given back.
select is(report_day('2026-11-10') -> 'net', '{"items": 50.00, "tax": 4.13, "total": 54.13}'::jsonb,
          'the net is worked out on the server');
select is(report_day('2026-11-12') -> 'net', '{"items": -20.00, "tax": -1.65, "total": -21.65}'::jsonb,
          'a day of refunds nets below zero');
select throws_ok($$ select report_day(((now() at time zone 'America/Chicago')::date + 1)) $$, '22023',
                 'That day hasn''t happened yet', 'a day still to come is refused');

select open_drawer((select id from drawers where name = 'Main drawer'), '{}');
select throws_ok($$ select close_drawer((select id from drawer_sessions), '{}', repeat('x', 501)) $$, '22023',
                 'Keep the note to 500 characters', 'a long close note gets a plain message');
select throws_ok($$ select record_drawer_movement((select id from drawer_sessions), 'paid_in', 10000000) $$, '22023',
                 'That amount is too large', 'a huge amount gets a plain message');

select * from finish();
rollback;
