-- A customer's email/text opt-in (Phase 3E): stamped, checked, kept in
-- history.
begin;
\ir helpers/setup.psql

select plan(24);

-- ---------------------------------------------------------------------------
-- Usable contact details
-- ---------------------------------------------------------------------------
select is(phone_e164('(415)555-0123'), '+14155550123', 'a formatted US number');
select is(phone_e164('1 415 555 0123'), '+14155550123', 'with the country code');
select is(phone_e164('+1 (415) 555-0123'), '+14155550123', 'typed with +1');
select is(phone_e164('+44 20 7946 0958'), '+442079460958', 'an international number');
select is(phone_e164('555-0123'), null, 'too short');
select is(phone_e164('(115)555-0123'), null, 'an area code can''t start with 1');
select is(phone_e164('415-555-0123 x12'), null, 'an extension isn''t textable');
select is(phone_e164(null), null, 'no number');
select ok(is_valid_email(' sam@example.com '), 'an email address');
select ok(not is_valid_email('sam@example'), 'no domain ending');
select ok(not is_valid_email(null), 'no address');

-- ---------------------------------------------------------------------------
-- Opting in
-- ---------------------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');

select throws_like(
  $$ insert into customers (first_name, last_name, email_opt_in) values ('No', 'Email', true) $$,
  'Add a valid email address before opting in to emails', 'no email, no email opt-in');
select throws_like(
  $$ insert into customers (first_name, last_name, phone_number, sms_opt_in) values ('Bad', 'Phone', '555-0123', true) $$,
  'Add a mobile number (10 digits) before opting in to texts', 'a short number can''t opt in to texts');

insert into customers (id, first_name, last_name, email, phone_number, email_opt_in)
values ('00000000-0000-0000-0000-0000000000c5', 'Opt', 'In', 'opt@example.com', '(415)555-0123', true);
select results_eq(
  $$ select email_opt_in, email_opt_in_by, email_opt_in_at is not null, sms_opt_in, sms_opt_in_at
       from customers where id = '00000000-0000-0000-0000-0000000000c5' $$,
  $$ values (true, '00000000-0000-0000-0000-0000000000a1'::uuid, true, false, null::timestamptz) $$,
  'opting in when added is stamped with who and when');
select results_eq(
  $$ select channel, opted_in, reason, changed_by from customer_opt_in_changes
      where customer_id = '00000000-0000-0000-0000-0000000000c5' $$,
  $$ values ('email'::text, true, 'Opted in when the customer was added'::text, '00000000-0000-0000-0000-0000000000a1'::uuid) $$,
  'and kept in the history');

update customers set sms_opt_in = true where id = '00000000-0000-0000-0000-0000000000c5';
select is((select sms_opt_in_by from customers where id = '00000000-0000-0000-0000-0000000000c5'),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'texts opted in later');

-- Another edit leaves the stamps alone, and can't fake them.
update customers set first_name = 'Opal', email_opt_in_at = '2000-01-01', sms_opt_in_by = null
 where id = '00000000-0000-0000-0000-0000000000c5';
select results_eq(
  $$ select email_opt_in_at > '2020-01-01', sms_opt_in_by from customers where id = '00000000-0000-0000-0000-0000000000c5' $$,
  $$ values (true, '00000000-0000-0000-0000-0000000000a1'::uuid) $$,
  'stamps can''t be edited directly');
select is((select count(*)::int from customer_opt_in_changes where customer_id = '00000000-0000-0000-0000-0000000000c5'),
          2, 'an edit that doesn''t change an opt-in adds no history');

-- Clearing the number turns texts off, with the reason.
update customers set phone_number = '' where id = '00000000-0000-0000-0000-0000000000c5';
select results_eq(
  $$ select c.sms_opt_in, h.reason from customers c
       join customer_opt_in_changes h on h.customer_id = c.id and h.channel = 'sms' and not h.opted_in
      where c.id = '00000000-0000-0000-0000-0000000000c5' $$,
  $$ values (false, 'Phone number removed'::text) $$,
  'clearing the phone number turns texts off');
update customers set email = null where id = '00000000-0000-0000-0000-0000000000c5';
select is((select reason from customer_opt_in_changes
            where customer_id = '00000000-0000-0000-0000-0000000000c5' and channel = 'email' and not opted_in),
          'Email address removed', 'clearing the email turns emails off');
select throws_like(
  $$ update customers set email = 'not-an-address', email_opt_in = true where id = '00000000-0000-0000-0000-0000000000c5' $$,
  'Add a valid email address before opting in to emails', 'a bad address can''t opt in');

-- ---------------------------------------------------------------------------
-- The history is read-only
-- ---------------------------------------------------------------------------
select throws_like(
  $$ insert into customer_opt_in_changes (customer_id, channel, opted_in, reason)
     values ('00000000-0000-0000-0000-0000000000c5', 'sms', true, 'fake') $$,
  'permission denied%', 'staff can''t write consent history');
select is((select count(*)::int from customer_opt_in_changes where customer_id = '00000000-0000-0000-0000-0000000000c5'),
          4, 'staff can read it');

select tests.act_as_anon();
select throws_like($$ select count(*) from customer_opt_in_changes $$, 'permission denied%', 'signed-out visitors can''t read it');

select * from finish();
rollback;
