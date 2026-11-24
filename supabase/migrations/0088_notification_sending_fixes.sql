-- =============================================================================
-- 0088_notification_sending_fixes.sql — sending customer messages, review fixes
-- (AceStock, Phase 3E review)
--
-- Before (0086):
--   • Send again (resend_notification) took only failed or skipped messages.
--     A message left waiting (the sender was down) or stuck "sending" could
--     never be sent, and nothing else sent it (review #1).
--   • The sender's duplicate-protection key was the message id plus its try
--     count. A message that went out but wasn't recorded was taken again
--     after 10 minutes with a new key, so the email service sent it twice
--     (review #3).
--   • A queued ready message was sent even if the customer had since opted
--     out, changed address, been made inactive or deleted, or the job had
--     moved on (review #5); Send again also allowed a ready message for a job
--     already delivered or cancelled (review #10).
--   • Send again then asked the sender for "this job's or sale's" messages;
--     when that job or sale had been deleted, the request named neither and
--     the whole shop's queue went (review #9).
--   • A message stuck "sending" was taken again forever (review #15).
--
-- Now:
--   1. notifications.resend_count: raised only when Send again puts a
--      finished (failed or not-sent) message back. The sender's key is the
--      message id plus this count, so a retry of the same send is never
--      delivered twice, and only Send again makes a new send.
--   2. claim_notifications takes an optional message id (p_id) so Send again
--      sends exactly that message. Before handing a ready message to the
--      sender it checks again that the job is still complete and the
--      customer still exists, is active, is opted in to that channel and has
--      the same address; if not, the message is recorded as not sent, with
--      the reason. A message already tried 5 times is recorded as failed.
--   3. resend_notification also takes a waiting message, or one stuck
--      "sending" for 10 minutes; a ready message only while its job is
--      complete (waiting for pickup).
--
-- Re-runnable.
-- =============================================================================

alter table notifications add column if not exists resend_count integer not null default 0;
comment on column notifications.resend_count is
  'Times staff used Send again on a finished message; part of the sender''s duplicate-protection key';

-- The most times a message is handed to the sender before it is given up.
create or replace function notification_max_attempts()
returns integer
language sql
immutable
set search_path = public, pg_temp
as $$ select 5 $$;
revoke all on function notification_max_attempts() from public, anon, authenticated;

-- Why a ready message should no longer go, or null when it still should.
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
    if btrim(coalesce(v_customer.email, '')) is distinct from p_message.to_address then
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

-- -----------------------------------------------------------------------------
-- The sender's claim (service role only)
-- -----------------------------------------------------------------------------
drop function if exists claim_notifications(uuid, uuid, integer);
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
       where id = v_row.id;
      continue;
    end if;
    v_reason := job_ready_stale_reason(v_row);
    if v_reason is not null then
      update notifications
         set status = 'skipped', finished_at = now(), error = v_reason
       where id = v_row.id;
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

-- -----------------------------------------------------------------------------
-- Sending again (staff)
-- -----------------------------------------------------------------------------
create or replace function resend_notification(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row      notifications%rowtype;
  v_customer customers%rowtype;
  v_status   text;
  v_to       text;
  v_finished boolean;
begin
  perform require_staff();
  select * into v_row from notifications where id = p_id for update;
  if not found then
    raise exception 'Unknown message %', p_id;
  end if;
  if v_row.status = 'sent' then
    raise exception 'This message was already sent';
  end if;
  if v_row.status = 'sending' and v_row.sending_at >= now() - interval '10 minutes' then
    raise exception 'This message is being sent now; try again in a few minutes';
  end if;
  v_finished := v_row.status in ('failed', 'skipped');
  v_to := v_row.to_address;

  if v_row.kind = 'job_ready' then
    select status into v_status from string_jobs where id = v_row.string_job_id;
    if v_status is null then
      raise exception 'The job was deleted, so there''s nothing to tell the customer';
    end if;
    if v_status <> 'complete' then
      raise exception 'The job is %, so the ready message can''t be sent', v_status;
    end if;
    select * into v_customer from customers where id = v_row.customer_id;
    if not found or not v_customer.is_active then
      raise exception 'This customer is inactive, so they aren''t sent messages';
    end if;
    if v_row.channel = 'email' then
      if not v_customer.email_opt_in or not is_valid_email(v_customer.email) then
        raise exception '% has opted out of emails', v_customer.first_name;
      end if;
      v_to := btrim(v_customer.email);
    else
      if not v_customer.sms_opt_in or phone_e164(v_customer.phone_number) is null then
        raise exception '% has opted out of texts', v_customer.first_name;
      end if;
      v_to := phone_e164(v_customer.phone_number);
    end if;
  end if;

  -- A finished message is a new send (new key); a waiting or stuck one is the
  -- same send, so if it did go out, the email service drops the repeat.
  update notifications
     set status = 'queued', to_address = v_to, error = null, provider_id = null,
         sending_at = null, finished_at = null, attempts = 0,
         resend_count = resend_count + case when v_finished then 1 else 0 end
   where id = p_id;
  return p_id;
end;
$$;
revoke all on function resend_notification(uuid) from public, anon;
grant execute on function resend_notification(uuid) to authenticated;
