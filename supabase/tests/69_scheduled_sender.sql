-- Queued customer messages go out on a 5-minute schedule (0107).
begin;
\ir helpers/setup.psql

select plan(13);

-- ---------------------------------------------------------------------------
-- Nobody signed in can set it up, check a secret or start a sweep
-- ---------------------------------------------------------------------------
select ok(not has_function_privilege('authenticated', 'set_up_notification_sweep(text, text)', 'execute')
          and not has_function_privilege('authenticated', 'notification_sweep_allowed(text)', 'execute')
          and not has_function_privilege('authenticated', 'request_notification_sweep()', 'execute'),
          'signed-in users can''t call the sweep functions');
select ok(has_function_privilege('service_role', 'notification_sweep_allowed(text)', 'execute')
          and not has_function_privilege('service_role', 'request_notification_sweep()', 'execute'),
          'the Edge Function (service role) can only check a secret');
select is((select schedule from cron.job where jobname = 'acestock-send-notifications'), '*/5 * * * *',
          'the sweep runs every 5 minutes');

-- ---------------------------------------------------------------------------
-- Not set up: nothing is sent
-- ---------------------------------------------------------------------------
delete from vault.secrets where name like 'acestock_%';
insert into notifications (kind, channel, to_address, subject, body)
values ('receipt', 'email', 'pat@test.local', 'Receipt', 'Thanks');
select is(request_notification_sweep(), null::bigint, 'without set-up the sweep does nothing');
select is(notification_sweep_allowed('anything'), false, 'and no secret is good');

-- ---------------------------------------------------------------------------
-- Set up
-- ---------------------------------------------------------------------------
select throws_ok($$ select set_up_notification_sweep('not a url', 'key') $$, 'P0001',
                 'The project address looks like https://<project>.supabase.co', 'a bad address is refused');
select throws_ok($$ select set_up_notification_sweep('https://abc.supabase.co', '  ') $$, 'P0001',
                 'The project''s anon key is needed', 'the anon key is needed');
select set_up_notification_sweep('https://abc.supabase.co/', 'anon-key');
create temp table first_secret as
  select decrypted_secret as s from vault.decrypted_secrets where name = 'acestock_sweep_secret';
select set_up_notification_sweep('https://abc.supabase.co', 'anon-key-2');
select is((select decrypted_secret from vault.decrypted_secrets where name = 'acestock_sweep_secret'),
          (select s from first_secret), 'setting up again keeps the same sweep secret');
select is(length((select s from first_secret)), 64, 'which is long and random');

select is(notification_sweep_allowed((select s from first_secret)), true, 'the Edge Function accepts the secret');
select is(notification_sweep_allowed('guess'), false, 'and nothing else');

-- ---------------------------------------------------------------------------
-- A sweep posts to the Edge Function, with the secret, when something waits
-- ---------------------------------------------------------------------------
create temp table req as select request_notification_sweep() as id;
select results_eq(
  $$ select url, headers->>'x-acestock-sweep' = (select s from first_secret), headers->>'Authorization', body::text
       from net.http_request_queue where id = (select id from req) $$,
  $$ values ('https://abc.supabase.co/functions/v1/send-notifications'::text, true, 'Bearer anon-key-2'::text,
             convert_to('{"sweep": true}', 'UTF8')::text) $$,
  'a waiting message starts a sweep with the secret and the anon key');

update notifications set status = 'sent', finished_at = now();
select is(request_notification_sweep(), null::bigint, 'with nothing waiting, no request is made');

select * from finish();
rollback;
