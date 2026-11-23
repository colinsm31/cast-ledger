-- Backstops from the Phase 3C review (0073).
begin;
\ir helpers/setup.psql

select plan(3);

-- Every table has the staff-only write check of 0041, including tables added
-- after it: a new table fails here until it gets the trigger.
select is(
  (select array_agg(c.relname::text order by c.relname)
     from pg_class c
    where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
      and not exists (select 1 from pg_trigger t where t.tgrelid = c.oid and t.tgname = 'trg_enforce_staff_writer')),
  null::text[],
  'every table refuses writes from accounts without staff access');

select tests.create_staff('00000000-0000-0000-0000-0000000000a3', 'pending@test.local', 'pending');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a3');
select throws_ok($$ insert into held_tickets (name, ticket, expires_at) values ('x', '{}', now() + interval '1 hour') $$,
                 '42501', 'This account hasn''t been approved for staff access yet',
                 'including tables added after 0041, like held tickets');

-- A customer with only demo history can't be deleted, and the message says why.
select tests.clear_authentication();
insert into customers (id, first_name, last_name) values ('00000000-0000-0000-0000-0000000000c2', 'Sam', 'Other');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select receive_units('00000000-0000-0000-0000-0000000000b2', '["RV-1"]');
select set_unit_status((select id from product_units where barcode = 'RV-1'), 'demo', 'Demo fleet');
select check_in_demo(check_out_demo((select id from product_units where barcode = 'RV-1'),
                                    '00000000-0000-0000-0000-0000000000c2'));
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select throws_like($$ delete from customers where id = '00000000-0000-0000-0000-0000000000c2' $$,
                   'Sam Other has demo history, so they can''t be deleted',
                   'deleting a customer with demos says they have demo history');

select * from finish();
rollback;
