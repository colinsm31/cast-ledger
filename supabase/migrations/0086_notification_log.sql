-- =============================================================================
-- 0086_notification_log.sql — the customer message log and the "ready" queue
-- (AceStock, Phase 3E)
--
-- Before:
--   • Marking a string job complete (advance_string_job, 0064) told nobody;
--     staff phoned the customer.
--
-- Now:
--   1. notifications: one row per message to a customer — what kind (a job is
--      ready; a receipt, from 0087), by email or text, to which address, the
--      words sent, and where it stands: queued → sending → sent, failed or
--      skipped (texting isn't set up; test mode). Staff can read it; only the
--      functions below write it.
--   2. Settings hold the "ready" templates an admin edits, with {first_name},
--      {last_name}, {job_number}, {racquet} and {shop_name} filled in.
--   3. When a job becomes complete, queue_job_ready queues one message per
--      channel the customer opted into (0085), in the same transaction, so a
--      message is queued exactly when the job is complete.
--   4. claim_notifications / finish_notification are for the server-side
--      sender (the send-notifications Edge Function, service role only): a
--      claim takes queued rows (SKIP LOCKED, so two senders never take the
--      same one) and marks them sending; finish records the outcome.
--   5. resend_notification: staff put a failed or skipped message back in the
--      queue. A ready message is only resent while the customer is still
--      opted in, to their current address.
--
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Templates
-- -----------------------------------------------------------------------------
alter table settings add column if not exists ready_email_subject text not null
  default 'Your racquet is ready at {shop_name}';
alter table settings add column if not exists ready_email_body text not null
  default E'Hi {first_name},\n\nYour {racquet} is strung and ready to pick up (job {job_number}).\n\nThanks,\n{shop_name}';
alter table settings add column if not exists ready_sms_body text not null
  default 'Hi {first_name}, your {racquet} is strung and ready at {shop_name} (job {job_number}). Reply STOP to opt out.';

alter table settings drop constraint if exists ck_settings_ready_templates;
alter table settings add constraint ck_settings_ready_templates check (
  char_length(btrim(ready_email_subject)) between 1 and 150
  and char_length(btrim(ready_email_body)) between 1 and 2000
  and char_length(btrim(ready_sms_body)) between 1 and 320
);

comment on column settings.ready_email_subject is 'Subject of the "stringing ready" email; placeholders like {first_name}';
comment on column settings.ready_email_body    is 'Body of the "stringing ready" email';
comment on column settings.ready_sms_body      is 'The "stringing ready" text message';

-- Fills {name} placeholders from p_values; an unknown placeholder is left as
-- typed so a typo shows in the preview.
create or replace function render_template(p_template text, p_values jsonb)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_text text := coalesce(p_template, '');
  v_key  text;
  v_val  text;
begin
  for v_key, v_val in select key, value from jsonb_each_text(coalesce(p_values, '{}'::jsonb)) loop
    v_text := replace(v_text, '{' || v_key || '}', coalesce(v_val, ''));
  end loop;
  return v_text;
end;
$$;
grant execute on function render_template(text, jsonb) to authenticated;

-- -----------------------------------------------------------------------------
-- 2. The log
-- -----------------------------------------------------------------------------
create table if not exists notifications (
  id             uuid primary key default gen_random_uuid(),
  kind           text not null check (kind in ('job_ready', 'receipt')),
  channel        text not null check (channel in ('email', 'sms')),
  customer_id    uuid references customers (id) on delete set null,
  string_job_id  uuid references string_jobs (id) on delete set null,
  sale_id        uuid references sales (id) on delete set null,
  to_address     text not null check (char_length(to_address) between 3 and 254),
  subject        text,
  body           text not null,
  html           text,
  status         text not null default 'queued'
                   check (status in ('queued', 'sending', 'sent', 'failed', 'skipped')),
  provider_id    text,
  error          text,
  attempts       integer not null default 0,
  created_by     uuid references profiles (id) default auth.uid(),
  created_at     timestamptz not null default now(),
  sending_at     timestamptz,
  finished_at    timestamptz,
  check (channel = 'email' or (subject is null and html is null))
);
create index if not exists notifications_customer_idx on notifications (customer_id, created_at desc);
create index if not exists notifications_job_idx on notifications (string_job_id) where string_job_id is not null;
create index if not exists notifications_sale_idx on notifications (sale_id, created_at desc) where sale_id is not null;
create index if not exists notifications_queued_idx on notifications (created_at) where status in ('queued', 'sending');
comment on table notifications is
  'Every message sent (or tried) to a customer: ready notices and emailed receipts';

alter table notifications enable row level security;
drop policy if exists notifications_staff_read on notifications;
create policy notifications_staff_read on notifications
  for select to authenticated using (is_staff());
revoke all on notifications from anon, authenticated;
grant select on notifications to authenticated;
drop trigger if exists trg_enforce_staff_writer on notifications;
create trigger trg_enforce_staff_writer before insert or update or delete on notifications
  for each statement execute function enforce_staff_writer();

-- -----------------------------------------------------------------------------
-- 3. Queueing the "ready" message
-- -----------------------------------------------------------------------------
-- The values a ready template fills in, for one job.
create or replace function job_ready_values(p_job_id uuid)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
           'first_name', c.first_name,
           'last_name',  c.last_name,
           'job_number', 'J' || j.job_number,
           'racquet',    coalesce(nullif(btrim(concat_ws(' ', r.brand, r.model)), ''), 'racquet'),
           'shop_name',  coalesce(nullif(btrim(s.shop_name), ''), 'the shop'))
    from string_jobs j
    join customer_rackets r on r.id = j.customer_racket_id
    join customers c on c.id = r.customer_id
    cross join settings s
   where j.id = p_job_id
$$;
revoke all on function job_ready_values(uuid) from public, anon;
grant execute on function job_ready_values(uuid) to authenticated;

-- Security definer so the trigger can write the log, which staff can't.
create or replace function queue_job_ready()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_customer customers%rowtype;
  v_values   jsonb;
  v_settings settings%rowtype;
begin
  if new.status <> 'complete' or old.status = 'complete' then
    return null;
  end if;
  select c.* into v_customer
    from customer_rackets r join customers c on c.id = r.customer_id
   where r.id = new.customer_racket_id;
  if not found or not v_customer.is_active then
    return null;
  end if;
  select * into v_settings from settings where id;
  v_values := job_ready_values(new.id);

  if v_customer.email_opt_in and is_valid_email(v_customer.email) then
    insert into notifications (kind, channel, customer_id, string_job_id, to_address, subject, body)
    values ('job_ready', 'email', v_customer.id, new.id, btrim(v_customer.email),
            render_template(v_settings.ready_email_subject, v_values),
            render_template(v_settings.ready_email_body, v_values));
  end if;
  if v_customer.sms_opt_in and phone_e164(v_customer.phone_number) is not null then
    insert into notifications (kind, channel, customer_id, string_job_id, to_address, body)
    values ('job_ready', 'sms', v_customer.id, new.id, phone_e164(v_customer.phone_number),
            render_template(v_settings.ready_sms_body, v_values));
  end if;
  return null;
end;
$$;
revoke all on function queue_job_ready() from public, anon, authenticated;

drop trigger if exists trg_queue_job_ready on string_jobs;
create trigger trg_queue_job_ready after update of status on string_jobs
  for each row execute function queue_job_ready();

-- -----------------------------------------------------------------------------
-- 4. The sender's side (service role only)
-- -----------------------------------------------------------------------------
-- Takes up to p_limit queued messages — for one job, one sale, or the oldest
-- of any — and marks them sending. A message left "sending" for 10 minutes
-- (a sender that died) is taken again.
create or replace function claim_notifications(
  p_string_job_id uuid default null,
  p_sale_id       uuid default null,
  p_limit         integer default 20
)
returns setof notifications
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  return query
  with picked as (
    select n.id
      from notifications n
     where (n.status = 'queued' or (n.status = 'sending' and n.sending_at < now() - interval '10 minutes'))
       and (p_string_job_id is null or n.string_job_id = p_string_job_id)
       and (p_sale_id is null or n.sale_id = p_sale_id)
     order by n.created_at
     limit least(greatest(coalesce(p_limit, 20), 1), 100)
     for update skip locked
  )
  update notifications n
     set status = 'sending', sending_at = now(), attempts = n.attempts + 1, error = null
    from picked
   where n.id = picked.id
  returning n.*;
end;
$$;
revoke all on function claim_notifications(uuid, uuid, integer) from public, anon, authenticated;
grant execute on function claim_notifications(uuid, uuid, integer) to service_role;

-- Records how a claimed message went. A text refused because the customer
-- replied STOP (p_opted_out) also turns their text opt-in off.
create or replace function finish_notification(
  p_id          uuid,
  p_status      text,
  p_provider_id text default null,
  p_error       text default null,
  p_opted_out   boolean default false
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
  if v_row.status <> 'sending' then
    raise exception 'This message isn''t being sent (it is %)', v_row.status;
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
revoke all on function finish_notification(uuid, text, text, text, boolean) from public, anon, authenticated;
grant execute on function finish_notification(uuid, text, text, text, boolean) to service_role;

-- -----------------------------------------------------------------------------
-- 5. Sending again
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
  v_to       text;
begin
  perform require_staff();
  select * into v_row from notifications where id = p_id for update;
  if not found then
    raise exception 'Unknown message %', p_id;
  end if;
  if v_row.status not in ('failed', 'skipped') then
    raise exception 'Only a message that failed or wasn''t sent can be sent again';
  end if;
  v_to := v_row.to_address;

  if v_row.kind = 'job_ready' then
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

  update notifications
     set status = 'queued', to_address = v_to, error = null, provider_id = null,
         sending_at = null, finished_at = null
   where id = p_id;
  return p_id;
end;
$$;
revoke all on function resend_notification(uuid) from public, anon;
grant execute on function resend_notification(uuid) to authenticated;
