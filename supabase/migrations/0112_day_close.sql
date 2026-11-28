-- =============================================================================
-- 0112_day_close.sql — closing a business day, and keeping it closed
-- (AceStock, Phase 4B)
--
-- Adds:
--   1. day_closes — each close of a business day: who and when, and the daily
--      report as it stood (report_day, 0111), so the Z report reprints the
--      same. A day reopened by an admin keeps its row (reopened_at/by, an
--      optional reason); closing it again adds a new row. One open close per
--      day.
--   2. close_day(day) — any staff member, once every drawer opened on or
--      before that day is closed; not a day still to come.
--   3. reopen_day(day, reason) — admins only; the reason is optional (0093).
--   4. A closed day is locked: no new sale, refund (or exchange), gift card
--      or store credit change, drawer opened, or paid-in/out dated that day
--      in the shop's time zone. Stock, string jobs, customers and products
--      aren't affected, and a sale from a closed day can still be refunded
--      (the refund is dated today).
--   Closing takes a lock that every locked write shares, so a write either
--   finishes first and is in the day's report, or waits and is refused.
--
-- Re-runnable.
-- =============================================================================

-- 1. day_closes ---------------------------------------------------------------------
create table if not exists day_closes (
  id            uuid primary key default gen_random_uuid(),
  business_day  date not null,
  closed_at     timestamptz not null default now(),
  closed_by     uuid default auth.uid() references profiles (id),
  report        jsonb not null,
  reopened_at   timestamptz,
  reopened_by   uuid references profiles (id),
  reopen_reason text check (char_length(reopen_reason) <= 500)
);
comment on table day_closes is 'Each close of a business day, with its daily report as closed (0112)';
create unique index if not exists uq_day_closes_closed on day_closes (business_day) where reopened_at is null;

alter table day_closes enable row level security;
drop policy if exists day_closes_staff_select on day_closes;
create policy day_closes_staff_select on day_closes for select to authenticated using (is_staff());
revoke all on day_closes from anon, authenticated;
grant select on day_closes to authenticated;

drop trigger if exists trg_enforce_staff_writer on day_closes;
create trigger trg_enforce_staff_writer before insert or update or delete on day_closes
  for each statement execute function enforce_staff_writer();

-- The lock closing takes (exclusive) and locked writes share.
create or replace function day_close_lock_key()
returns bigint
language sql
immutable
set search_path = public, pg_temp
as $$
  select hashtextextended('acestock.day_close', 0);
$$;
revoke all on function day_close_lock_key() from public, anon, authenticated;

-- 2. close_day ----------------------------------------------------------------------
create or replace function close_day(p_day date)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_open text;
  v_id   uuid;
begin
  perform require_staff();
  if p_day is null then
    raise exception 'Choose a day' using errcode = '22023';
  end if;
  if p_day > shop_day(now()) then
    raise exception 'A day can''t be closed before it has started' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(day_close_lock_key());

  if exists (select 1 from day_closes where business_day = p_day and reopened_at is null) then
    raise exception 'That day is already closed' using errcode = '22023';
  end if;
  select string_agg(dr.name, ', ' order by dr.name) into v_open
    from drawer_sessions ds join drawers dr on dr.id = ds.drawer_id
   where ds.closed_at is null and ds.business_day <= p_day;
  if v_open is not null then
    raise exception 'Count and close every drawer first (still open: %)', v_open using errcode = '22023';
  end if;

  insert into day_closes (business_day, report)
  values (p_day, report_day(p_day))
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function close_day(date) from public, anon;
grant execute on function close_day(date) to authenticated;

-- 3. reopen_day -----------------------------------------------------------------------
create or replace function reopen_day(p_day date, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform require_staff();
  if auth.uid() is not null and not is_admin() then
    raise exception 'Only an admin can reopen a closed day' using errcode = '42501';
  end if;
  if char_length(btrim(p_reason)) > 500 then
    raise exception 'Keep the reason to 500 characters' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(day_close_lock_key());

  update day_closes
     set reopened_at = now(),
         reopened_by = auth.uid(),
         reopen_reason = nullif(btrim(p_reason), '')
   where business_day = p_day and reopened_at is null;
  if not found then
    raise exception 'That day isn''t closed' using errcode = '22023';
  end if;
end;
$$;
revoke all on function reopen_day(date, text) from public, anon;
grant execute on function reopen_day(date, text) to authenticated;

-- 4. Closed days are locked -------------------------------------------------------
-- Whether a business day is closed now.
create or replace function is_day_closed(p_day date)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select exists (select 1 from day_closes where business_day = p_day and reopened_at is null);
$$;
revoke all on function is_day_closed(date) from public, anon;
grant execute on function is_day_closed(date) to authenticated;

-- Refuses a row dated on a closed day. The trigger's argument names the row's
-- date: a timestamp column (its day in the shop's time zone) or a date column.
create or replace function guard_closed_day()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_zone  text;
  v_value text := to_jsonb(new) ->> tg_argv[0];
  v_day   date;
begin
  select time_zone into v_zone from settings where id;
  if v_zone is null or v_value is null then
    return new;  -- no days can be closed without the shop's time zone
  end if;
  perform pg_advisory_xact_lock_shared(day_close_lock_key());
  if v_value ~ '^\d{4}-\d{2}-\d{2}$' then
    v_day := v_value::date;
  else
    v_day := (v_value::timestamptz at time zone v_zone)::date;
  end if;
  if is_day_closed(v_day) then
    raise exception 'That business day (%) has been closed. An admin can reopen it on the End of Day screen',
      to_char(v_day, 'FMDy FMMon FMDD')
      using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function guard_closed_day() from public, anon, authenticated;

drop trigger if exists trg_sales_closed_day on sales;
create trigger trg_sales_closed_day before insert on sales
  for each row execute function guard_closed_day('sold_at');
drop trigger if exists trg_refunds_closed_day on refunds;
create trigger trg_refunds_closed_day before insert on refunds
  for each row execute function guard_closed_day('refunded_at');
drop trigger if exists trg_gift_card_txns_closed_day on gift_card_txns;
create trigger trg_gift_card_txns_closed_day before insert on gift_card_txns
  for each row execute function guard_closed_day('created_at');
drop trigger if exists trg_store_credit_txns_closed_day on store_credit_txns;
create trigger trg_store_credit_txns_closed_day before insert on store_credit_txns
  for each row execute function guard_closed_day('created_at');
drop trigger if exists trg_drawer_sessions_closed_day on drawer_sessions;
create trigger trg_drawer_sessions_closed_day before insert on drawer_sessions
  for each row execute function guard_closed_day('business_day');
drop trigger if exists trg_drawer_movements_closed_day on drawer_movements;
create trigger trg_drawer_movements_closed_day before insert on drawer_movements
  for each row execute function guard_closed_day('created_at');
