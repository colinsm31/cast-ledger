-- =============================================================================
-- 0107_scheduled_sender.sql — queued customer messages go out on their own (AceStock)
--
-- Before: a message was sent only when the screen that queued it asked
-- (completing a job, emailing a receipt) or when staff pressed Send again. A
-- message that couldn't go then (email down, the screen closed) waited until
-- someone noticed.
--
-- Now every 5 minutes the database asks the send-notifications Edge Function
-- to send what's waiting (pg_cron + pg_net):
--   1. set_up_notification_sweep(project_url, anon_key) — run once per
--      environment by whoever looks after it (not by the app): keeps the
--      project's address and its public anon key in the Vault and creates a
--      random sweep secret there that nobody sees or copies.
--   2. notification_sweep_allowed(secret) — the Edge Function asks this (with
--      the service role) whether a sweep request carries that secret.
--   3. request_notification_sweep() — what the schedule runs: when anything
--      is waiting (queued, or stuck sending over 10 minutes) and the sweep is
--      set up, it posts { "sweep": true } with the secret. Otherwise nothing.
--   4. The schedule "acestock-send-notifications", every 5 minutes.
-- None of these can be called by a signed-in user.
--
-- Re-runnable.
-- =============================================================================

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- 1. Set up (once per environment) ---------------------------------------------
create or replace function set_up_notification_sweep(p_project_url text, p_anon_key text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_url text := rtrim(btrim(coalesce(p_project_url, '')), '/');
begin
  if v_url !~ '^https?://[^/\s]+$' then
    raise exception 'The project address looks like https://<project>.supabase.co';
  end if;
  if nullif(btrim(coalesce(p_anon_key, '')), '') is null then
    raise exception 'The project''s anon key is needed';
  end if;

  delete from vault.secrets where name in ('acestock_project_url', 'acestock_anon_key');
  perform vault.create_secret(v_url, 'acestock_project_url', 'Where the message sweep sends (0107)');
  perform vault.create_secret(btrim(p_anon_key), 'acestock_anon_key', 'Public anon key for the message sweep (0107)');
  -- The sweep secret is made here once and kept: nobody types or copies it.
  if not exists (select 1 from vault.secrets where name = 'acestock_sweep_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'acestock_sweep_secret',
                                'Proves a message sweep came from this database (0107)');
  end if;
end;
$$;

revoke all on function set_up_notification_sweep(text, text) from public, anon, authenticated, service_role;

-- 2. The Edge Function's check ------------------------------------------------
create or replace function notification_sweep_allowed(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select decrypted_secret = p_secret from vault.decrypted_secrets where name = 'acestock_sweep_secret'),
    false)
  and coalesce(p_secret, '') <> '';
$$;

revoke all on function notification_sweep_allowed(text) from public, anon, authenticated;
grant execute on function notification_sweep_allowed(text) to service_role;

-- 3. What the schedule runs ----------------------------------------------------
create or replace function request_notification_sweep()
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_url    text;
  v_anon   text;
  v_secret text;
begin
  select decrypted_secret into v_url    from vault.decrypted_secrets where name = 'acestock_project_url';
  select decrypted_secret into v_anon   from vault.decrypted_secrets where name = 'acestock_anon_key';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'acestock_sweep_secret';
  if v_url is null or v_anon is null or v_secret is null then
    return null;  -- not set up in this environment
  end if;
  if not exists (select 1 from notifications
                  where status = 'queued' or (status = 'sending' and sending_at < now() - interval '10 minutes')) then
    return null;  -- nothing waiting
  end if;
  return net.http_post(
    url     := v_url || '/functions/v1/send-notifications',
    body    := jsonb_build_object('sweep', true),
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_anon,
                 'x-acestock-sweep', v_secret),
    timeout_milliseconds := 30000);
end;
$$;

revoke all on function request_notification_sweep() from public, anon, authenticated, service_role;

-- 4. The schedule ----------------------------------------------------------------
select cron.schedule('acestock-send-notifications', '*/5 * * * *', 'select public.request_notification_sweep()');
