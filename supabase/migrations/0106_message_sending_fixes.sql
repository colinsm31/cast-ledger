-- =============================================================================
-- 0106_message_sending_fixes.sql — customer message fixes (AceStock, 4A review of 3E)
--
--   1. job_ready_stale_reason: an email address that differs only in case or
--      spaces is the same address, as the customer's record already treats it
--      (0089). A queued ready message was skipped as "address changed" after
--      such an edit.
--   2. claim_notifications also returns the messages it gives up on or skips,
--      with the reason, so the sender can tell staff ("Ready message not sent:
--      the customer opted out of emails"). They're returned finished, not to
--      send. Otherwise as 0088.
--   3. finish_notification takes the try it answers for (p_attempt). A try
--      that stalled, was taken again after 10 minutes, and answers late no
--      longer overwrites the newer try's outcome, and an email that went out
--      is recorded as sent even if a newer try failed first. Without p_attempt
--      it works as before. Otherwise as 0086.
-- The send-notifications Edge Function passes the try and reports the
-- returned skips (deployed with this migration).
--
-- Re-runnable.
-- =============================================================================

drop function if exists finish_notification(uuid, text, text, text, boolean);

create or replace function job_ready_stale_reason(p_message notifications)
returns text
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_customer customers%rowtype;
  v_status   text;
begin
  if p_message.kind <> 'job_ready' then
    return null;
  end if;
  select status into v_status from string_jobs where id = p_message.string_job_id;
  if v_status is null then
    return 'The job was deleted, so the message wasn''t sent';
  end if;
  if v_status <> 'complete' then
    return format('The job is %s, so the ready message wasn''t sent', v_status);
  end if;
  select * into v_customer from customers where id = p_message.customer_id;
  if not found then
    return 'The customer was deleted, so the message wasn''t sent';
  end if;
  if not v_customer.is_active then
    return 'The customer is inactive, so the message wasn''t sent';
  end if;
  if p_message.channel = 'email' then
    if not v_customer.email_opt_in then
      return 'The customer opted out of emails, so the message wasn''t sent';
    end if;
    -- Case and spaces don't make a new address, as on the customer's record (0106).
    if lower(btrim(coalesce(v_customer.email, ''))) is distinct from lower(btrim(p_message.to_address)) then
      return 'The customer''s email address changed, so the message wasn''t sent';
    end if;
  else
    if not v_customer.sms_opt_in then
      return 'The customer opted out of texts, so the message wasn''t sent';
    end if;
    if phone_e164(v_customer.phone_number) is distinct from p_message.to_address then
      return 'The customer''s mobile number changed, so the message wasn''t sent';
    end if;
  end if;
  return null;
end;
$$;
revoke all on function job_ready_stale_reason(notifications) from public, anon, authenticated;

create or replace function claim_notifications(
  p_string_job_id uuid default null,
  p_sale_id       uuid default null,
  p_limit         integer default 20,
  p_id            uuid default null
)
returns setof notifications
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row    notifications%rowtype;
  v_reason text;
begin
  for v_row in
    select n.*
      from notifications n
     where (n.status = 'queued' or (n.status = 'sending' and n.sending_at < now() - interval '10 minutes'))
       and (p_string_job_id is null or n.string_job_id = p_string_job_id)
       and (p_sale_id is null or n.sale_id = p_sale_id)
       and (p_id is null or n.id = p_id)
     order by n.created_at
     limit least(greatest(coalesce(p_limit, 20), 1), 100)
     for update skip locked
  loop
    if v_row.attempts >= notification_max_attempts() then
      update notifications
         set status = 'failed', finished_at = now(),
             error = format('Gave up after %s tries; use Send again to try once more', v_row.attempts)
       where id = v_row.id
      returning * into v_row;
      -- Returned so the sender can tell staff (0106); it isn't sent.
      return next v_row;
      continue;
    end if;
    v_reason := job_ready_stale_reason(v_row);
    if v_reason is not null then
      update notifications
         set status = 'skipped', finished_at = now(), error = v_reason
       where id = v_row.id
      returning * into v_row;
      -- Returned so the sender can tell staff why (0106); it isn't sent.
      return next v_row;
      continue;
    end if;
    update notifications
       set status = 'sending', sending_at = now(), attempts = attempts + 1, error = null
     where id = v_row.id
    returning * into v_row;
    return next v_row;
  end loop;
end;
$$;
revoke all on function claim_notifications(uuid, uuid, integer, uuid) from public, anon, authenticated;
grant execute on function claim_notifications(uuid, uuid, integer, uuid) to service_role;

create or replace function finish_notification(
  p_id          uuid,
  p_status      text,
  p_provider_id text default null,
  p_error       text default null,
  p_opted_out   boolean default false,
  p_attempt     integer default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row notifications%rowtype;
begin
  if p_status not in ('sent', 'failed', 'skipped') then
    raise exception 'A message finishes as sent, failed or skipped';
  end if;
  select * into v_row from notifications where id = p_id for update;
  if not found then
    raise exception 'Unknown message %', p_id;
  end if;
  -- An email that went out is sent, even if a try that stalled and was taken
  -- again (after 10 minutes) reports it late, or a newer try failed first.
  if p_status = 'sent' and v_row.status in ('sending', 'failed') then
    null;
  elsif v_row.status <> 'sending' then
    raise exception 'This message isn''t being sent (it is %)', v_row.status;
  elsif p_attempt is not null and p_attempt <> v_row.attempts then
    -- A late answer from an earlier try: the newer try has the last word (0106).
    return;
  end if;
  update notifications
     set status      = p_status,
         provider_id = left(p_provider_id, 200),
         error       = left(nullif(btrim(coalesce(p_error, '')), ''), 500),
         finished_at = now()
   where id = p_id;

  if p_opted_out and v_row.channel = 'sms' and v_row.customer_id is not null then
    perform set_config('acestock.opt_in_reason', 'The customer replied STOP', true);
    update customers set sms_opt_in = false where id = v_row.customer_id and sms_opt_in;
    perform set_config('acestock.opt_in_reason', '', true);
  end if;
end;
$$;
revoke all on function finish_notification(uuid, text, text, text, boolean, integer) from public, anon, authenticated;
grant execute on function finish_notification(uuid, text, text, text, boolean, integer) to service_role;
