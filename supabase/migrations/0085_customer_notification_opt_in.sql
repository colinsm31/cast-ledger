-- =============================================================================
-- 0085_customer_notification_opt_in.sql — a customer's say on being told
-- when their stringing is ready (AceStock, Phase 3E)
--
-- Before:
--   • customers had a phone_number and an email (0012) but no record of
--     whether they wanted to hear from the shop.
--
-- Now:
--   1. customers.email_opt_in / sms_opt_in, each with when and by whom it was
--      last changed. Staff tick them on the customer's form, as today's
--      customer edits work (direct update under RLS).
--   2. A trigger stamps who and when, refuses an opt-in with no usable email
--      or phone, and turns an opt-in off when its email or phone is cleared.
--   3. customer_opt_in_changes keeps every change (customer, channel, on or
--      off, who, when, why), so the shop can show when consent was given.
--   4. phone_e164 / is_valid_email: the forms a message can be sent to.
--
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Usable contact details
-- -----------------------------------------------------------------------------
-- A phone number a text can go to: a US number of 10 digits (with or without
-- a leading 1, any punctuation) becomes +1XXXXXXXXXX; a number typed with a
-- leading + keeps its 8–15 digits. Anything else (an extension, too short) is
-- null.
create or replace function phone_e164(p_phone text)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_text   text := btrim(coalesce(p_phone, ''));
  v_digits text := regexp_replace(v_text, '\D', '', 'g');
begin
  if v_text ~ '^\+' and v_text !~ '^\+1' then
    if v_text ~ '^\+[0-9 ().-]+$' and length(v_digits) between 8 and 15 then
      return '+' || v_digits;
    end if;
    return null;
  end if;
  if v_text !~ '^\+?[0-9 ().-]+$' then
    return null;
  end if;
  if length(v_digits) = 11 and left(v_digits, 1) = '1' then
    v_digits := substr(v_digits, 2);
  end if;
  if length(v_digits) = 10 and left(v_digits, 1) between '2' and '9' then
    return '+1' || v_digits;
  end if;
  return null;
end;
$$;
grant execute on function phone_e164(text) to authenticated;

create or replace function is_valid_email(p_email text)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(btrim(p_email) ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' and char_length(btrim(p_email)) <= 254, false)
$$;
grant execute on function is_valid_email(text) to authenticated;

-- -----------------------------------------------------------------------------
-- 2. Columns and history
-- -----------------------------------------------------------------------------
alter table customers add column if not exists email_opt_in        boolean not null default false;
alter table customers add column if not exists email_opt_in_at     timestamptz;
alter table customers add column if not exists email_opt_in_by     uuid references profiles (id);
alter table customers add column if not exists sms_opt_in          boolean not null default false;
alter table customers add column if not exists sms_opt_in_at       timestamptz;
alter table customers add column if not exists sms_opt_in_by       uuid references profiles (id);

comment on column customers.email_opt_in is 'The customer agreed to be emailed when their stringing is ready';
comment on column customers.sms_opt_in   is 'The customer agreed to be texted when their stringing is ready';
comment on column customers.email_opt_in_at is 'When email_opt_in last changed';
comment on column customers.sms_opt_in_at   is 'When sms_opt_in last changed';

create table if not exists customer_opt_in_changes (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers (id) on delete cascade,
  channel     text not null check (channel in ('email', 'sms')),
  opted_in    boolean not null,
  reason      text not null check (char_length(reason) between 1 and 200),
  changed_by  uuid references profiles (id),
  changed_at  timestamptz not null default now()
);
create index if not exists customer_opt_in_changes_customer_idx
  on customer_opt_in_changes (customer_id, changed_at desc);
comment on table customer_opt_in_changes is
  'Every change to a customer''s email/SMS opt-in: proof of when consent was given or withdrawn';

alter table customer_opt_in_changes enable row level security;
drop policy if exists customer_opt_in_changes_staff_read on customer_opt_in_changes;
create policy customer_opt_in_changes_staff_read on customer_opt_in_changes
  for select to authenticated using (is_staff());
revoke all on customer_opt_in_changes from anon, authenticated;
grant select on customer_opt_in_changes to authenticated;
-- Every table refuses writes from accounts without staff access (0041, 0073).
drop trigger if exists trg_enforce_staff_writer on customer_opt_in_changes;
create trigger trg_enforce_staff_writer before insert or update or delete on customer_opt_in_changes
  for each statement execute function enforce_staff_writer();

-- -----------------------------------------------------------------------------
-- 3. Stamping and checking opt-ins
-- -----------------------------------------------------------------------------
-- Runs as the caller: it only fills in the row being saved.
create or replace function stamp_customer_opt_in()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- Clearing the address or number turns its opt-in off rather than failing
  -- the edit; the history says why.
  if tg_op = 'UPDATE' and new.email_opt_in and nullif(btrim(coalesce(new.email, '')), '') is null then
    new.email_opt_in := false;
  end if;
  if tg_op = 'UPDATE' and new.sms_opt_in and nullif(btrim(coalesce(new.phone_number, '')), '') is null then
    new.sms_opt_in := false;
  end if;

  if new.email_opt_in and not is_valid_email(new.email) then
    raise exception 'Add a valid email address before opting in to emails';
  end if;
  if new.sms_opt_in and phone_e164(new.phone_number) is null then
    raise exception 'Add a mobile number (10 digits) before opting in to texts';
  end if;

  if tg_op = 'INSERT' then
    new.email_opt_in_at := case when new.email_opt_in then now() end;
    new.email_opt_in_by := case when new.email_opt_in then auth.uid() end;
    new.sms_opt_in_at   := case when new.sms_opt_in then now() end;
    new.sms_opt_in_by   := case when new.sms_opt_in then auth.uid() end;
    return new;
  end if;

  if new.email_opt_in is distinct from old.email_opt_in then
    new.email_opt_in_at := now();
    new.email_opt_in_by := auth.uid();
  else
    new.email_opt_in_at := old.email_opt_in_at;
    new.email_opt_in_by := old.email_opt_in_by;
  end if;
  if new.sms_opt_in is distinct from old.sms_opt_in then
    new.sms_opt_in_at := now();
    new.sms_opt_in_by := auth.uid();
  else
    new.sms_opt_in_at := old.sms_opt_in_at;
    new.sms_opt_in_by := old.sms_opt_in_by;
  end if;
  return new;
end;
$$;
revoke all on function stamp_customer_opt_in() from public, anon, authenticated;

drop trigger if exists trg_stamp_customer_opt_in on customers;
create trigger trg_stamp_customer_opt_in before insert or update on customers
  for each row execute function stamp_customer_opt_in();

-- The history row is written after the change, once the customer row exists.
-- (Not an UPDATE OF trigger: clearing a phone turns sms_opt_in off without
-- the edit naming that column.)
-- Security definer only so it can write the history table, which staff can't
-- write directly. A function that turns an opt-in off for a reason of its own
-- (a refused address, later) sets acestock.opt_in_reason first.
create or replace function log_customer_opt_in()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_reason text := coalesce(nullif(current_setting('acestock.opt_in_reason', true), ''),
                            case when tg_op = 'INSERT' then 'Opted in when the customer was added'
                                 else 'Changed on the customer''s record' end);
begin
  if new.email_opt_in is distinct from (case when tg_op = 'INSERT' then false else old.email_opt_in end) then
    insert into customer_opt_in_changes (customer_id, channel, opted_in, reason, changed_by)
    values (new.id, 'email', new.email_opt_in,
            case when tg_op = 'UPDATE' and not new.email_opt_in and nullif(btrim(coalesce(new.email, '')), '') is null
                      and old.email is not null then 'Email address removed' else v_reason end,
            auth.uid());
  end if;
  if new.sms_opt_in is distinct from (case when tg_op = 'INSERT' then false else old.sms_opt_in end) then
    insert into customer_opt_in_changes (customer_id, channel, opted_in, reason, changed_by)
    values (new.id, 'sms', new.sms_opt_in,
            case when tg_op = 'UPDATE' and not new.sms_opt_in and nullif(btrim(coalesce(new.phone_number, '')), '') is null
                      and old.phone_number is not null then 'Phone number removed' else v_reason end,
            auth.uid());
  end if;
  return null;
end;
$$;
revoke all on function log_customer_opt_in() from public, anon, authenticated;

drop trigger if exists trg_log_customer_opt_in on customers;
create trigger trg_log_customer_opt_in after insert or update on customers
  for each row execute function log_customer_opt_in();
