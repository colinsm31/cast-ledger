-- Sending customer messages: the 0088 review fixes.
begin;
\ir helpers/setup.psql

select plan(27);

-- Ann is opted in to both; three of her jobs are complete (waiting for pickup).
insert into customers (id, first_name, last_name, email, phone_number, email_opt_in, sms_opt_in) values
  ('00000000-0000-0000-0000-0000000000d1', 'Ann', 'Notify', 'ann@example.com', '(415)555-0101', true, true);
insert into customer_rackets (id, customer_id, model) values
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000d1', 'Frame one'),
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000d1', 'Frame two'),
  ('00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-0000000000d1', 'Frame three');
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, strung_by) values
  ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-0000000000e1',
   '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 'Pat'),
  ('00000000-0000-0000-0000-000000000e02', '00000000-0000-0000-0000-0000000000e2',
   '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 'Pat'),
  ('00000000-0000-0000-0000-000000000e03', '00000000-0000-0000-0000-0000000000e3',
   '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 'Pat');
update string_jobs set status = 'complete' where id::text like '00000000-0000-0000-0000-000000000e0_';
-- The messages that queued are set aside; each check below adds its own.
delete from notifications;

-- A ready message for job e01 (or another), as the trigger would queue it.
create function pg_temp.note(p_channel text, p_to text,
                             p_job uuid default '00000000-0000-0000-0000-000000000e01',
                             p_customer uuid default '00000000-0000-0000-0000-0000000000d1')
returns uuid language sql as $$
  insert into notifications (kind, channel, customer_id, string_job_id, to_address, subject, body)
  values ('job_ready', p_channel, p_customer, p_job, p_to,
          case when p_channel = 'email' then 'Ready' end, 'Your racquet is ready')
  returning id
$$;
create function pg_temp.claim(p_id uuid) returns integer language sql as $$
  select count(*)::int from claim_notifications(p_id => p_id)
$$;
create function pg_temp.outcome(p_id uuid) returns text language sql as $$
  select status || ': ' || coalesce(error, '') from notifications where id = p_id
$$;

-- ---------------------------------------------------------------------------
-- Claiming one message, and checking it should still go (#5, #9)
-- ---------------------------------------------------------------------------
create temp table m (name text primary key, id uuid);
grant select on m to authenticated;
insert into m values
  ('email', pg_temp.note('email', 'ann@example.com')),
  ('sms',   pg_temp.note('sms', '+14155550101'));
select is(job_ready_stale_reason((select n from notifications n where id = (select id from m where name = 'email'))),
          null, 'a ready message to a customer still opted in, at the same address, is still good');
select is(pg_temp.claim((select id from m where name = 'email')), 1, 'the sender claims one message by its id');
select is((select status from notifications where id = (select id from m where name = 'sms')), 'queued',
          'and leaves the others waiting');
select is((select resend_count from notifications where id = (select id from m where name = 'email')), 0,
          'a new message hasn''t been sent again');

insert into m values ('old email', pg_temp.note('email', 'old@example.com'));
select is(pg_temp.claim((select id from m where name = 'old email')), 0, 'a message to an old address isn''t sent');
select is(pg_temp.outcome((select id from m where name = 'old email')),
          'skipped: The customer''s email address changed, so the message wasn''t sent', 'and says why');

insert into m values ('old number', pg_temp.note('sms', '+14155550199'));
select is(pg_temp.claim((select id from m where name = 'old number')), 0, 'nor a text to an old number');
select is(pg_temp.outcome((select id from m where name = 'old number')),
          'skipped: The customer''s mobile number changed, so the message wasn''t sent', 'and says why');

update customers set sms_opt_in = false where id = '00000000-0000-0000-0000-0000000000d1';
select is(pg_temp.claim((select id from m where name = 'sms')), 0, 'a text queued before the customer opted out isn''t sent');
select is(pg_temp.outcome((select id from m where name = 'sms')),
          'skipped: The customer opted out of texts, so the message wasn''t sent', 'and says why');

update customers set email_opt_in = false where id = '00000000-0000-0000-0000-0000000000d1';
insert into m values ('opted out', pg_temp.note('email', 'ann@example.com'));
select is(pg_temp.claim((select id from m where name = 'opted out')), 0, 'nor an email');
select is(pg_temp.outcome((select id from m where name = 'opted out')),
          'skipped: The customer opted out of emails, so the message wasn''t sent', 'and says why');

-- A receipt was asked for at the counter: it goes without an opt-in.
with r as (
  insert into notifications (kind, channel, customer_id, to_address, subject, body)
  values ('receipt', 'email', '00000000-0000-0000-0000-0000000000d1', 'ann@example.com', 'Receipt', 'Receipt')
  returning id)
insert into m select 'receipt', id from r;
select is(pg_temp.claim((select id from m where name = 'receipt')), 1, 'a receipt isn''t held back by the opt-in');
update customers set email_opt_in = true where id = '00000000-0000-0000-0000-0000000000d1';

select set_config('acestock.set_active', 'on', true);
update customers set is_active = false where id = '00000000-0000-0000-0000-0000000000d1';
insert into m values ('inactive', pg_temp.note('email', 'ann@example.com'));
select is(pg_temp.claim((select id from m where name = 'inactive')) || ' ' || pg_temp.outcome((select id from m where name = 'inactive')),
          '0 skipped: The customer is inactive, so the message wasn''t sent', 'nor to a customer made inactive');
update customers set is_active = true where id = '00000000-0000-0000-0000-0000000000d1';
select set_config('acestock.set_active', '', true);

insert into m values ('no customer', pg_temp.note('email', 'ann@example.com', p_customer => null));
select is(pg_temp.claim((select id from m where name = 'no customer')) || ' ' || pg_temp.outcome((select id from m where name = 'no customer')),
          '0 skipped: The customer was deleted, so the message wasn''t sent', 'nor to a deleted customer');

insert into m values ('no job', pg_temp.note('email', 'ann@example.com', p_job => null));
select is(pg_temp.claim((select id from m where name = 'no job')) || ' ' || pg_temp.outcome((select id from m where name = 'no job')),
          '0 skipped: The job was deleted, so the message wasn''t sent', 'nor for a deleted job');

update string_jobs set status = 'delivered' where id = '00000000-0000-0000-0000-000000000e02';
insert into m values ('delivered', pg_temp.note('email', 'ann@example.com', p_job => '00000000-0000-0000-0000-000000000e02'));
select is(pg_temp.claim((select id from m where name = 'delivered')) || ' ' || pg_temp.outcome((select id from m where name = 'delivered')),
          '0 skipped: The job is delivered, so the ready message wasn''t sent', 'nor for a job already picked up');

-- ---------------------------------------------------------------------------
-- Giving up (#15)
-- ---------------------------------------------------------------------------
insert into m values ('stuck 4', pg_temp.note('email', 'ann@example.com')), ('stuck 5', pg_temp.note('email', 'ann@example.com'));
update notifications set status = 'sending', sending_at = now() - interval '11 minutes',
       attempts = case when id = (select id from m where name = 'stuck 4') then 4 else 5 end
 where id in (select id from m where name like 'stuck _');
select is(pg_temp.claim((select id from m where name = 'stuck 4')), 1, 'a message stuck sending after 4 tries is tried a 5th time');
select is(pg_temp.claim((select id from m where name = 'stuck 5')) || ' ' || pg_temp.outcome((select id from m where name = 'stuck 5')),
          '0 failed: Gave up after 5 tries; use Send again to try once more', 'after 5 it is given up');

-- ---------------------------------------------------------------------------
-- Send again (#1, #3, #10)
-- ---------------------------------------------------------------------------
insert into m values ('waiting', pg_temp.note('email', 'ann@example.com')), ('fresh', pg_temp.note('email', 'ann@example.com'));
update notifications set attempts = 2 where id = (select id from m where name = 'waiting');
update notifications set status = 'sending', sending_at = now() - interval '1 minute', attempts = 1
 where id = (select id from m where name = 'fresh');
update notifications set status = 'sent' where id = (select id from m where name = 'email');
update notifications set sending_at = now() - interval '11 minutes' where id = (select id from m where name = 'stuck 4');
update notifications set status = 'failed', error = 'Timed out', attempts = 5, finished_at = now()
 where id = (select id from m where name = 'stuck 5');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select resend_notification((select id from m where name = 'waiting'));
select results_eq($$ select status, attempts, resend_count from notifications where id = (select id from m where name = 'waiting') $$,
                  $$ values ('queued'::text, 0, 0) $$, 'a message left waiting can be sent again, as the same send');
select throws_like($$ select resend_notification((select id from m where name = 'fresh')) $$,
                   'This message is being sent now; try again in a few minutes', 'not while it is being sent');
select resend_notification((select id from m where name = 'stuck 4'));
select results_eq($$ select status, resend_count from notifications where id = (select id from m where name = 'stuck 4') $$,
                  $$ values ('queued'::text, 0) $$, 'one stuck sending can, still as the same send');
select resend_notification((select id from m where name = 'stuck 5'));
select results_eq($$ select status, attempts, resend_count, error from notifications where id = (select id from m where name = 'stuck 5') $$,
                  $$ values ('queued'::text, 0, 1, null::text) $$, 'a failed one is sent again as a new send');
select throws_like($$ select resend_notification((select id from m where name = 'email')) $$,
                   'This message was already sent', 'a sent message isn''t sent again');
select throws_like($$ select resend_notification((select id from m where name = 'delivered')) $$,
                   'The job is delivered, so the ready message can''t be sent', 'nor a ready message for a job picked up');

select tests.clear_authentication();
update string_jobs set status = 'cancelled' where id = '00000000-0000-0000-0000-000000000e03';
insert into m values ('cancelled', pg_temp.note('email', 'ann@example.com', p_job => '00000000-0000-0000-0000-000000000e03'));
update notifications set status = 'failed' where id = (select id from m where name = 'cancelled');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like($$ select resend_notification((select id from m where name = 'cancelled')) $$,
                   'The job is cancelled, so the ready message can''t be sent', 'or cancelled');
select throws_like($$ select resend_notification((select id from m where name = 'no job')) $$,
                   'The job was deleted, so there''s nothing to tell the customer', 'or deleted');

select * from finish();
rollback;
