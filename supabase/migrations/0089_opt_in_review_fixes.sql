-- =============================================================================
-- 0089_opt_in_review_fixes.sql — consent follows the address (AceStock,
-- Phase 3E review)
--
-- Before (0085):
--   • Changing a customer's email or mobile number kept their opt-in, so
--     messages went to the new address with no consent recorded for it
--     (review #7). An opted-in customer whose address was changed to an
--     unusable one couldn't be saved at all (review #11).
--   • Deleting a customer deleted their consent history (on delete cascade),
--     while the log of messages sent to them was kept (review #8).
--
-- Now:
--   1. stamp_customer_opt_in: an edit that changes the email (ignoring case
--      and spaces) or the mobile number (ignoring formatting) turns that
--      opt-in off; the history says "Email address changed" / "Mobile number
--      changed". To keep sending, staff ask the customer again and tick the
--      box, which is recorded as a new opt-in for the new address.
--   2. customer_opt_in_changes keeps its rows when the customer is deleted
--      (customer_id is set to null), like the message log.
--
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Consent follows the address
-- -----------------------------------------------------------------------------
create or replace function stamp_customer_opt_in()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' then
    -- A new (or removed) address or number needs the customer's say again,
    -- so its opt-in is turned off rather than carried over (0089). Clearing
    -- one is a change too.
    if old.email_opt_in
       and lower(btrim(coalesce(new.email, ''))) is distinct from lower(btrim(coalesce(old.email, ''))) then
      new.email_opt_in := false;
    end if;
    if old.sms_opt_in
       and phone_e164(new.phone_number) is distinct from phone_e164(old.phone_number) then
      new.sms_opt_in := false;
    end if;
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

-- The history's reason for a change the edit didn't ask for.
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
            case when tg_op = 'UPDATE' and not new.email_opt_in
                      and nullif(current_setting('acestock.opt_in_reason', true), '') is null
                      and lower(btrim(coalesce(new.email, ''))) is distinct from lower(btrim(coalesce(old.email, ''))) then
                   case when nullif(btrim(coalesce(new.email, '')), '') is null then 'Email address removed'
                        else 'Email address changed' end
                 else v_reason end,
            auth.uid());
  end if;
  if new.sms_opt_in is distinct from (case when tg_op = 'INSERT' then false else old.sms_opt_in end) then
    insert into customer_opt_in_changes (customer_id, channel, opted_in, reason, changed_by)
    values (new.id, 'sms', new.sms_opt_in,
            case when tg_op = 'UPDATE' and not new.sms_opt_in
                      and nullif(current_setting('acestock.opt_in_reason', true), '') is null
                      and phone_e164(new.phone_number) is distinct from phone_e164(old.phone_number) then
                   case when nullif(btrim(coalesce(new.phone_number, '')), '') is null then 'Phone number removed'
                        else 'Mobile number changed' end
                 else v_reason end,
            auth.uid());
  end if;
  return null;
end;
$$;
revoke all on function log_customer_opt_in() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. The history outlives the customer
-- -----------------------------------------------------------------------------
alter table customer_opt_in_changes alter column customer_id drop not null;
alter table customer_opt_in_changes drop constraint if exists customer_opt_in_changes_customer_id_fkey;
alter table customer_opt_in_changes add constraint customer_opt_in_changes_customer_id_fkey
  foreign key (customer_id) references customers (id) on delete set null;
