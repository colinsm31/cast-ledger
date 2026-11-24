-- Consent follows the address (0089).
begin;
\ir helpers/setup.psql

select plan(10);

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
insert into customers (id, first_name, last_name, email, phone_number, email_opt_in, sms_opt_in)
values ('00000000-0000-0000-0000-0000000000d5', 'Kim', 'Moves', 'kim@example.com', '(415)555-0123', true, true);

create function pg_temp.opt_ins() returns text language sql as $$
  select email_opt_in || '/' || sms_opt_in from customers where id = '00000000-0000-0000-0000-0000000000d5'
$$;
create function pg_temp.last_reason(p_channel text) returns text language sql as $$
  select reason from customer_opt_in_changes
   where customer_id = '00000000-0000-0000-0000-0000000000d5' and channel = p_channel
   order by changed_at desc, opted_in limit 1
$$;

-- The same address typed differently is the same address.
update customers set email = ' KIM@example.com ', phone_number = '415 555 0123'
 where id = '00000000-0000-0000-0000-0000000000d5';
select is(pg_temp.opt_ins(), 'true/true', 'retyping the same address or number keeps the opt-ins');

-- A new address needs the customer's say again (#7).
update customers set email = 'kim.new@example.com', email_opt_in = true where id = '00000000-0000-0000-0000-0000000000d5';
select is(pg_temp.opt_ins(), 'false/true', 'a new email address turns emails off, even with the box left ticked');
select is(pg_temp.last_reason('email'), 'Email address changed', 'and the history says why');
update customers set phone_number = '(415)555-0199' where id = '00000000-0000-0000-0000-0000000000d5';
select is(pg_temp.opt_ins(), 'false/false', 'a new mobile number turns texts off');
select is(pg_temp.last_reason('sms'), 'Mobile number changed', 'and the history says why');

-- Asked again, the customer opts in for the new address.
update customers set email_opt_in = true where id = '00000000-0000-0000-0000-0000000000d5';
select results_eq(
  $$ select email_opt_in, email_opt_in_by from customers where id = '00000000-0000-0000-0000-0000000000d5' $$,
  $$ values (true, '00000000-0000-0000-0000-0000000000a1'::uuid) $$, 'ticking the box again opts in for the new address');

-- An unusable address turns the opt-in off instead of failing the edit (#11).
update customers set email = 'kim@' where id = '00000000-0000-0000-0000-0000000000d5';
select is(pg_temp.opt_ins(), 'false/false', 'changing to an unusable address saves, with emails off');

-- Deleting the customer keeps their consent history (#8).
select tests.clear_authentication();
select is((select count(*)::int from customer_opt_in_changes where customer_id = '00000000-0000-0000-0000-0000000000d5'), 6,
          'six consent changes so far');
create temp table kept as select id from customer_opt_in_changes where customer_id = '00000000-0000-0000-0000-0000000000d5';
delete from customers where id = '00000000-0000-0000-0000-0000000000d5';
select is((select count(*)::int from customer_opt_in_changes where id in (select id from kept) and customer_id is null), 6,
          'deleting the customer keeps their consent history');
select is((select is_nullable from information_schema.columns
            where table_name = 'customer_opt_in_changes' and column_name = 'customer_id'), 'YES',
          'unlinked from the deleted customer');

select * from finish();
rollback;
