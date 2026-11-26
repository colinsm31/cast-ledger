-- Customer message fixes from the 4A review (0106).
begin;
\ir helpers/setup.psql

select plan(9);

insert into customers (id, first_name, last_name, email, phone_number, email_opt_in, sms_opt_in) values
  ('00000000-0000-0000-0000-0000000000d1', 'Ann', 'Notify', 'ann@example.com', '(415)555-0101', true, false);
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000d1', 'Frame one');
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, strung_by) values
  ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-0000000000e1',
   '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 'Pat');
update string_jobs set status = 'complete' where id = '00000000-0000-0000-0000-000000000e01';
delete from notifications;

create function pg_temp.note(p_to text) returns uuid language sql as $$
  insert into notifications (kind, channel, customer_id, string_job_id, to_address, subject, body)
  values ('job_ready', 'email', '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-000000000e01',
          p_to, 'Ready', 'Your racquet is ready')
  returning id
$$;

-- ---------------------------------------------------------------------------
-- 1. Case and spaces don't make a new address
-- ---------------------------------------------------------------------------
create temp table m (name text primary key, id uuid);
insert into m values ('ready', pg_temp.note('ann@example.com'));
update customers set email = ' Ann@Example.COM ' where id = '00000000-0000-0000-0000-0000000000d1';
select is((select email_opt_in from customers where id = '00000000-0000-0000-0000-0000000000d1'), true,
          'changing only the case keeps the opt-in (as before)');
select is(job_ready_stale_reason((select n from notifications n where id = (select id from m where name = 'ready'))),
          null, 'and the queued ready message still goes');

-- ---------------------------------------------------------------------------
-- 2. Skips and give-ups come back to the sender, finished, with the reason
-- ---------------------------------------------------------------------------
insert into m values ('old', pg_temp.note('old@example.com'));
select results_eq(
  $$ select status, error from claim_notifications(p_id => (select id from m where name = 'old')) $$,
  $$ values ('skipped'::text, 'The customer''s email address changed, so the message wasn''t sent'::text) $$,
  'a skipped message comes back to the sender with why, so staff are told');

insert into m values ('tired', pg_temp.note('ann@example.com'));
update notifications set attempts = notification_max_attempts() where id = (select id from m where name = 'tired');
select results_eq(
  $$ select status from claim_notifications(p_id => (select id from m where name = 'tired')) $$,
  $$ values ('failed'::text) $$,
  'so does one given up on');

-- ---------------------------------------------------------------------------
-- 3. A late answer from an earlier try doesn't overwrite the newer one
-- ---------------------------------------------------------------------------
-- Try 1 is taken, stalls, and is taken again as try 2 after 10 minutes.
create temp table first_try as select * from claim_notifications(p_id => (select id from m where name = 'ready'));
select is((select attempts from first_try), 1, 'the first try is try 1');
update notifications set sending_at = now() - interval '11 minutes' where id = (select id from m where name = 'ready');
create temp table second_try as select * from claim_notifications(p_id => (select id from m where name = 'ready'));
select is((select attempts from second_try), 2, 'taken again after 10 minutes as try 2');

-- Try 1 answers late with a timeout: ignored, try 2 is still sending.
select finish_notification((select id from m where name = 'ready'), 'failed', null, 'timed out', false, 1);
select is((select status from notifications where id = (select id from m where name = 'ready')), 'sending',
          'a late failure from the earlier try is ignored');

-- Try 2 fails first, then try 1's email turns out to have gone: it's sent.
select finish_notification((select id from m where name = 'ready'), 'failed', null, 'busy', false, 2);
select finish_notification((select id from m where name = 'ready'), 'sent', 're_123', null, false, 1);
select results_eq(
  $$ select status, provider_id, error from notifications where id = (select id from m where name = 'ready') $$,
  $$ values ('sent'::text, 're_123'::text, null::text) $$,
  'an email that went out is recorded as sent, even after a newer try failed');

-- And a sent message isn't turned back into a failure.
select throws_like(
  $$ select finish_notification((select id from m where name = 'ready'), 'failed', null, 'late', false, 2) $$,
  'This message isn''t being sent (it is sent)', 'a sent message can''t be marked failed');

select * from finish();
rollback;
