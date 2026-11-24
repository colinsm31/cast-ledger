-- The customer message log and the "ready" queue (Phase 3E).
begin;
\ir helpers/setup.psql

select plan(33);

update settings set shop_name = 'Ace Racquets' where id;
insert into customers (id, first_name, last_name, email, phone_number, email_opt_in, sms_opt_in) values
  ('00000000-0000-0000-0000-0000000000c5', 'Sam', 'Ready', 'sam@example.com', '(415)555-0123', true, true),
  ('00000000-0000-0000-0000-0000000000c6', 'Quiet', 'Player', 'quiet@example.com', null, false, false);
insert into customer_rackets (id, customer_id, brand, model) values
  ('00000000-0000-0000-0000-0000000000f5', '00000000-0000-0000-0000-0000000000c5', 'Wilson', 'Blade 98'),
  ('00000000-0000-0000-0000-0000000000f6', '00000000-0000-0000-0000-0000000000c6', null, 'Old frame'),
  ('00000000-0000-0000-0000-0000000000f7', '00000000-0000-0000-0000-0000000000c5', 'Head', 'Speed');
insert into string_jobs (id, customer_racket_id, main_product_id, cross_product_id, main_tension, cross_tension, strung_by) values
  ('00000000-0000-0000-0000-000000000f05', '00000000-0000-0000-0000-0000000000f5',
   '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 'Pat'),
  ('00000000-0000-0000-0000-000000000f07', '00000000-0000-0000-0000-0000000000f7',
   '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 'Pat'),
  ('00000000-0000-0000-0000-000000000f06', '00000000-0000-0000-0000-0000000000f6',
   '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1', 52, 52, 'Pat');

-- ---------------------------------------------------------------------------
-- Templates
-- ---------------------------------------------------------------------------
select is(render_template('Hi {first_name}, {first_name}! {unknown}', '{"first_name":"Sam"}'),
          'Hi Sam, Sam! {unknown}', 'placeholders are filled; unknown ones are left as typed');
select is(render_template(null, null), '', 'an empty template');
select is(job_ready_values('00000000-0000-0000-0000-000000000f05'),
          jsonb_build_object('first_name', 'Sam', 'last_name', 'Ready',
                             'job_number', 'J' || (select job_number from string_jobs where id = '00000000-0000-0000-0000-000000000f05'),
                             'racquet', 'Wilson Blade 98', 'shop_name', 'Ace Racquets'),
          'a job''s values');
select throws_like($$ update settings set ready_sms_body = repeat('x', 321) where id $$,
                   '%ck_settings_ready_templates%', 'a text template is at most 320 characters');
select throws_like($$ update settings set ready_email_subject = ' ' where id $$,
                   '%ck_settings_ready_templates%', 'a template can''t be empty');

-- ---------------------------------------------------------------------------
-- Completing a job queues its messages
-- ---------------------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select advance_string_job('00000000-0000-0000-0000-000000000f05', 'complete');
select results_eq(
  $$ select channel, to_address, subject, status, created_by from notifications
      where string_job_id = '00000000-0000-0000-0000-000000000f05' order by channel $$,
  $$ values ('email'::text, 'sam@example.com'::text, 'Your racquet is ready at Ace Racquets'::text, 'queued'::text,
             '00000000-0000-0000-0000-0000000000a1'::uuid),
            ('sms', '+14155550123', null, 'queued', '00000000-0000-0000-0000-0000000000a1') $$,
  'an email and a text are queued for the opted-in customer');
select ok((select body from notifications where string_job_id = '00000000-0000-0000-0000-000000000f05' and channel = 'sms')
          like 'Hi Sam, your Wilson Blade 98 is strung and ready at Ace Racquets (job J%). Reply STOP to opt out.',
          'the text is filled in from the template');
select ok((select body from notifications where string_job_id = '00000000-0000-0000-0000-000000000f05' and channel = 'email')
          like E'Hi Sam,\n\nYour Wilson Blade 98 is strung and ready to pick up (job J%', 'so is the email');

select advance_string_job('00000000-0000-0000-0000-000000000f06', 'complete');
select is((select count(*)::int from notifications where string_job_id = '00000000-0000-0000-0000-000000000f06'),
          0, 'a customer who hasn''t opted in gets nothing');
select tests.clear_authentication();
update string_jobs set status = 'delivered' where id = '00000000-0000-0000-0000-000000000f05';
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select is((select count(*)::int from notifications where string_job_id = '00000000-0000-0000-0000-000000000f05'),
          2, 'delivering the job queues nothing more');

-- Staff read the log but only the functions write it.
select throws_like(
  $$ insert into notifications (kind, channel, to_address, body) values ('receipt', 'email', 'x@example.com', 'hi') $$,
  'permission denied%', 'staff can''t add a message');
select throws_like($$ update notifications set status = 'sent' $$, 'permission denied%', 'or mark one sent');
select throws_like($$ select * from claim_notifications() $$, 'permission denied%', 'or claim messages to send');
select throws_like($$ select finish_notification(gen_random_uuid(), 'sent') $$, 'permission denied%',
                   'or finish one');

-- ---------------------------------------------------------------------------
-- The sender's side (run here as the database owner, like the service role)
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
select ok(has_function_privilege('service_role', 'claim_notifications(uuid, uuid, integer)', 'execute')
          and has_function_privilege('service_role', 'finish_notification(uuid, text, text, text, boolean)', 'execute'),
          'the service role can claim and finish');

select is((select count(*)::int from claim_notifications('00000000-0000-0000-0000-000000000f06')), 0,
          'nothing to claim for a job with no messages');
create temp table claimed as select * from claim_notifications('00000000-0000-0000-0000-000000000f05');
grant select on claimed to authenticated;
select results_eq($$ select count(*)::int, min(status), min(attempts) from claimed $$,
                  $$ values (2, 'sending'::text, 1) $$, 'both messages are claimed and marked sending');
select is((select count(*)::int from claim_notifications()), 0, 'a claimed message isn''t claimed again');

-- A sender that died: claimed again after 10 minutes.
update notifications set sending_at = now() - interval '11 minutes'
 where id = (select id from claimed where channel = 'email');
select results_eq($$ select channel, attempts from claim_notifications(p_limit => 5) $$,
                  $$ values ('email'::text, 2) $$, 'a message stuck sending is taken again');

select throws_like($$ select finish_notification((select id from claimed where channel = 'email'), 'queued') $$,
                   'A message finishes as sent, failed or skipped', 'only an outcome');
select throws_like($$ select finish_notification(gen_random_uuid(), 'sent') $$, 'Unknown message %', 'an unknown message');
select finish_notification((select id from claimed where channel = 'email'), 'sent', 'resend-123');
select results_eq(
  $$ select status, provider_id, finished_at is not null from notifications where id = (select id from claimed where channel = 'email') $$,
  $$ values ('sent'::text, 'resend-123'::text, true) $$, 'the email is recorded as sent');
select throws_like($$ select finish_notification((select id from claimed where channel = 'email'), 'failed') $$,
                   'This message isn''t being sent (it is sent)', 'a finished message stays finished');

-- The text is refused because Sam replied STOP: texts are turned off.
select finish_notification((select id from claimed where channel = 'sms'), 'failed', null, 'Unsubscribed recipient', true);
select results_eq(
  $$ select c.sms_opt_in, h.reason from customers c
       join customer_opt_in_changes h on h.customer_id = c.id and h.channel = 'sms' and not h.opted_in
      where c.id = '00000000-0000-0000-0000-0000000000c5' $$,
  $$ values (false, 'The customer replied STOP'::text) $$, 'a STOP reply turns the customer''s texts off');

-- ---------------------------------------------------------------------------
-- Sending again
-- ---------------------------------------------------------------------------
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like($$ select resend_notification((select id from claimed where channel = 'email')) $$,
                   'Only a message that failed or wasn''t sent can be sent again', 'a sent message isn''t resent');
select throws_like($$ select resend_notification((select id from claimed where channel = 'sms')) $$,
                   'Sam has opted out of texts', 'nor a text to someone who opted out');
select throws_like($$ select resend_notification(gen_random_uuid()) $$, 'Unknown message %', 'an unknown message');

-- A failed email goes again, to the customer's address as it is now.
select tests.clear_authentication();
update notifications set status = 'failed', error = 'Timed out'
 where id = (select id from claimed where channel = 'email');
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
update customers set email = 'sam.new@example.com' where id = '00000000-0000-0000-0000-0000000000c5';
select is(resend_notification((select id from claimed where channel = 'email')),
          (select id from claimed where channel = 'email'), 'a failed email is put back in the queue');
select results_eq(
  $$ select status, to_address, error from notifications where id = (select id from claimed where channel = 'email') $$,
  $$ values ('queued'::text, 'sam.new@example.com'::text, null::text) $$, 'to the current address');

select tests.clear_authentication();
update notifications set status = 'failed' where id = (select id from claimed where channel = 'email');
select set_config('acestock.set_active', 'on', true);
update customers set is_active = false where id = '00000000-0000-0000-0000-0000000000c5';
select set_config('acestock.set_active', '', true);
select tests.authenticate_as('00000000-0000-0000-0000-0000000000a1');
select throws_like($$ select resend_notification((select id from claimed where channel = 'email')) $$,
                   'This customer is inactive, so they aren''t sent messages', 'nothing goes to an inactive customer');

-- An inactive customer's completed job queues nothing (a job left open when
-- they were made inactive directly, as no screen allows).
select advance_string_job('00000000-0000-0000-0000-000000000f07', 'complete');
select is((select count(*)::int from notifications where string_job_id = '00000000-0000-0000-0000-000000000f07'),
          0, 'an inactive customer''s job queues no message');

select tests.authenticate_as('00000000-0000-0000-0000-0000000000a2');
select is((select count(*)::int from notifications where customer_id = '00000000-0000-0000-0000-0000000000c5'), 2,
          'staff can read the log');
select tests.act_as_anon();
select throws_like($$ select count(*) from notifications $$, 'permission denied%', 'signed-out visitors can''t');

select * from finish();
rollback;
