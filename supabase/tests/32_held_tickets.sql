-- Held tickets in the database: named, visible to all staff, expire, and
-- recalled by one register only (Phase 2D, #28).
begin;
\ir helpers/setup.psql

select plan(18);

create function tests.ticket(p_qty integer default 1) returns jsonb language sql immutable as $$
  select jsonb_build_object('lines', jsonb_build_array(jsonb_build_object(
    'key', 'k1', 'productId', '00000000-0000-0000-0000-0000000000b1', 'label', 'Test String 16',
    'price', '20', 'qty', p_qty)));
$$;
grant execute on function tests.ticket(integer) to authenticated;

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------------
-- Holding
-- ---------------------------------------------------------------------------
select throws_like($$ select hold_ticket('  ', null, tests.ticket()) $$, 'Give the held ticket a name', 'a name is needed');
select throws_like($$ select hold_ticket('Pat', null, '{"lines": []}') $$, 'There''s nothing on the ticket to hold',
                   'an empty ticket isn''t held');
select throws_like($$ select hold_ticket(repeat('x', 61), null, tests.ticket()) $$, '%at most 60 characters',
                   'a long name is refused');

create temp table h as select
  hold_ticket(' Pat ', '00000000-0000-0000-0000-0000000000c1', tests.ticket()) as first_id,
  hold_ticket('Walk-in', null, tests.ticket(2)) as second_id;
grant select on h to authenticated;
select results_eq(
  $$ select name, customer_id, held_by, expires_at > now() + interval '71 hours' from held_tickets order by name $$,
  $$ values ('Pat', '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000a1'::uuid, true),
            ('Walk-in', null::uuid, '00000000-0000-0000-0000-0000000000a1'::uuid, true) $$,
  'tickets are held by name, for the shop''s hours, several at once');

-- Another staff member sees them, from any register.
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select is((select count(*)::int from held_tickets), 2, 'other staff see every held ticket');

select lives_ok($$ select hold_ticket('Pat (racquet too)', '00000000-0000-0000-0000-0000000000c1', tests.ticket(3),
                                      (select first_id from h)) $$, 'a held ticket can be updated');
select results_eq($$ select name, (ticket->'lines'->0->>'qty')::int from held_tickets where id = (select first_id from h) $$,
                  $$ values ('Pat (racquet too)', 3) $$, 'with its new name and lines');

-- ---------------------------------------------------------------------------
-- Recalling
-- ---------------------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
create temp table r as select recall_held_ticket((select first_id from h)) as recalled;
select results_eq(
  $$ select recalled->>'name', (recalled->>'customer_id')::uuid, (recalled->'ticket'->'lines'->0->>'qty')::int from r $$,
  $$ values ('Pat (racquet too)', '00000000-0000-0000-0000-0000000000c1'::uuid, 3) $$,
  'recalling returns the ticket');
select is((select count(*)::int from held_tickets where id = (select first_id from h)), 0, 'and takes it off hold');
select throws_like($$ select recall_held_ticket((select first_id from h)) $$,
                   'That held ticket was recalled at another register or has expired', 'it can''t be recalled twice');
select throws_like($$ select hold_ticket('Pat', null, tests.ticket(), (select first_id from h)) $$,
                   'That held ticket was recalled at another register or has expired',
                   'or updated once another register recalled it');

-- ---------------------------------------------------------------------------
-- Expiring
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
update held_tickets set expires_at = now() - interval '1 minute' where id = (select second_id from h);
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select is((select count(*)::int from held_tickets where expires_at > now()), 0, 'an expired ticket isn''t listed');
select throws_like($$ select recall_held_ticket((select second_id from h)) $$,
                   'That held ticket was recalled at another register or has expired', 'and can''t be recalled');
select lives_ok($$ select hold_ticket('Next', null, tests.ticket()) $$, 'holding another ticket');
select tests.clear_authentication();
select is((select count(*)::int from held_tickets where id = (select second_id from h)), 0,
          'deletes expired tickets');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
update settings set held_ticket_hours = 2 where id;
select ok((select max(expires_at) from held_tickets) > now() + interval '71 hours', 'a new expiry time');
select lives_ok($$ select hold_ticket('Short', null, tests.ticket()) $$, 'applies');
select ok((select expires_at from held_tickets where name = 'Short') < now() + interval '3 hours',
          'to tickets held after it');

select * from finish();
rollback;
