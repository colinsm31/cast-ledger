-- =============================================================================
-- 0115_day_close_review_fixes.sql — closing the right day, and keeping it
-- closed (AceStock, 4B review 4, 6, 9, 10, 13)
--
--   1. unclosed_days(days) — the days in the last `days` (31) with sales,
--      refunds or drawers and no close, plus today if it isn't closed; End of
--      Day offers each, oldest first, so a close after midnight can pick the
--      day it means (review 4, 6).
--   2. Each close saves the exact moments its day ran from and to, and the
--      lock checks those: changing the time zone later can't move or lift a
--      closed day (review 9). The shop's time zone can't be cleared once set,
--      or changed while a drawer is open.
--   3. A drawer left open from an earlier day takes no new cash, paid-ins or
--      paid-outs until it's counted and closed (review 10), so each drawer's
--      count belongs to one business day.
--
-- register_drawer_session (0113), check_cash_drawer (0114) and
-- record_drawer_movement (0113) are as before except where marked; close_day
-- and guard_closed_day as in 0112 except where marked. Re-runnable.
-- =============================================================================

-- 2. The time each close covers -----------------------------------------------------
alter table day_closes add column if not exists closed_from timestamptz;
alter table day_closes add column if not exists closed_to   timestamptz;
update day_closes c
   set closed_from = c.business_day::timestamp at time zone s.time_zone,
       closed_to = (c.business_day + 1)::timestamp at time zone s.time_zone
  from settings s
 where s.id and c.closed_from is null and s.time_zone is not null;
comment on column day_closes.closed_from is 'When the closed business day began, in the shop''s time zone at the close (0115)';
comment on column day_closes.closed_to is 'When it ended (exclusive)';

create or replace function close_day(p_day date)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_open text;
  v_zone text;
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

  -- The moments the day ran from and to, kept with the close (review 9).
  select time_zone into v_zone from settings where id;
  insert into day_closes (business_day, report, closed_from, closed_to)
  values (p_day, report_day(p_day),
          p_day::timestamp at time zone v_zone, (p_day + 1)::timestamp at time zone v_zone)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function close_day(date) from public, anon;
grant execute on function close_day(date) to authenticated;

-- Refuses a row dated in a closed day: a timestamp inside a close's window, or
-- a business day that's closed (review 9: no time zone needed).
create or replace function guard_closed_day()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_value text := to_jsonb(new) ->> tg_argv[0];
  v_day   date;
begin
  if v_value is null then
    return new;
  end if;
  perform pg_advisory_xact_lock_shared(day_close_lock_key());
  if v_value ~ '^\d{4}-\d{2}-\d{2}$' then
    select business_day into v_day from day_closes
     where reopened_at is null and business_day = v_value::date;
  else
    select business_day into v_day from day_closes
     where reopened_at is null and v_value::timestamptz >= closed_from and v_value::timestamptz < closed_to;
  end if;
  if v_day is not null then
    raise exception 'That business day (%) has been closed. An admin can reopen it on the End of Day screen',
      to_char(v_day, 'FMDy FMMon FMDD')
      using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function guard_closed_day() from public, anon, authenticated;

-- The time zone can't be cleared once set, or changed while a drawer is open.
create or replace function check_settings_time_zone()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.time_zone is not null and not is_time_zone(new.time_zone) then
    raise exception 'Unknown time zone: %', new.time_zone using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' and new.time_zone is distinct from old.time_zone then
    if old.time_zone is not null and new.time_zone is null then
      raise exception 'The shop''s time zone can''t be cleared once it''s set' using errcode = '22023';
    end if;
    if exists (select 1 from drawer_sessions where closed_at is null) then
      raise exception 'Count and close every drawer before changing the time zone' using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function check_settings_time_zone() from public, anon, authenticated;

-- 3. A drawer left open from an earlier day ----------------------------------------
-- Raises if the drawer's open session began on an earlier business day.
create or replace function refuse_stale_drawer(p_drawer_id uuid)
returns void
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_day  date;
  v_name text;
begin
  if (select time_zone from settings where id) is null then
    return;
  end if;
  select ds.business_day, dr.name into v_day, v_name
    from drawer_sessions ds join drawers dr on dr.id = ds.drawer_id
   where ds.drawer_id = p_drawer_id and ds.closed_at is null;
  if v_day < shop_day(now()) then
    raise exception '% was opened on %. Count and close it, then open it again for today',
      v_name, to_char(v_day, 'FMDy FMMon FMDD')
      using errcode = '22023';
  end if;
end;
$$;
revoke all on function refuse_stale_drawer(uuid) from public, anon, authenticated;

create or replace function register_drawer_session()
returns uuid
language plpgsql
volatile
set search_path = public, pg_temp
as $$
declare
  v_drawer uuid := requested_drawer_id();
  v_ids    uuid[];
begin
  if v_drawer is null then
    select array_agg(id) into v_ids from (select id from drawers where is_active limit 2) d;
    if cardinality(v_ids) = 1 then
      v_drawer := v_ids[1];
    end if;
  end if;
  if v_drawer is null then
    return null;
  end if;
  select array_agg(id) into v_ids
    from (select id from drawer_sessions where drawer_id = v_drawer and closed_at is null for key share) s;
  -- A drawer left open from an earlier day takes no new cash (review 10).
  if v_ids[1] is not null and (select time_zone from settings where id) is not null
     and (select business_day from drawer_sessions where id = v_ids[1]) < shop_day(now()) then
    return null;
  end if;
  return v_ids[1];
end;
$$;
revoke all on function register_drawer_session() from public, anon, authenticated;

create or replace function check_cash_drawer()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_session uuid;
  v_action  text;
  v_drawer  drawers%rowtype;
begin
  if new.method <> 'cash'
     or not coalesce((select cash_needs_drawer and time_zone is not null from settings where id), false) then
    return new;
  end if;
  if tg_table_name = 'sale_payments' then
    select drawer_session_id into v_session from sales where id = new.sale_id;
    v_action := 'taking cash';
  else
    select drawer_session_id into v_session from refunds where id = new.refund_id;
    v_action := 'giving cash back';
  end if;
  if v_session is not null then
    return new;
  end if;

  -- The register's drawer: the one it names, else the only one in use (review 2).
  select * into v_drawer from drawers where id = requested_drawer_id();
  if not found and (select count(*) from drawers where is_active) = 1 then
    select * into v_drawer from drawers where is_active;
  end if;
  if v_drawer.id is not null then
    perform refuse_stale_drawer(v_drawer.id);
    raise exception 'Open % on the Cash drawer screen before %', v_drawer.name, v_action using errcode = '22023';
  end if;
  if exists (select 1 from drawers where is_active) then
    raise exception 'Choose this register''s drawer on the Cash drawer screen before %', v_action using errcode = '22023';
  end if;
  raise exception 'Add a cash drawer in Settings before %', v_action using errcode = '22023';
end;
$$;
revoke all on function check_cash_drawer() from public, anon, authenticated;

create or replace function record_drawer_movement(
  p_session_id uuid,
  p_kind       text,
  p_amount     numeric,
  p_reason     text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_closed_at timestamptz;
  v_expected  numeric;
  v_id        uuid;
begin
  perform require_staff();
  if p_kind is null or p_kind not in ('paid_in', 'paid_out') then
    raise exception 'Choose paid in or paid out' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Enter an amount over $0' using errcode = '22023';
  end if;
  if p_amount <> round(p_amount, 2) then
    raise exception 'Use at most 2 decimal places' using errcode = '22023';
  end if;
  if char_length(btrim(p_reason)) > 200 then
    raise exception 'Keep the reason to 200 characters' using errcode = '22023';
  end if;

  select closed_at into v_closed_at from drawer_sessions where id = p_session_id for no key update;
  if not found then
    raise exception 'Drawer session not found' using errcode = 'P0002';
  end if;
  if v_closed_at is not null then
    raise exception 'This drawer has been closed' using errcode = '22023';
  end if;
  perform refuse_stale_drawer((select drawer_id from drawer_sessions where id = p_session_id));
  if p_kind = 'paid_out' then
    select s.expected_cash into v_expected from drawer_cash_summary(p_session_id) s;
    if p_amount > v_expected then
      raise exception 'The drawer should only hold %', to_char(v_expected, 'FM$999,999,990.00')
        using errcode = '22023';
    end if;
  end if;

  insert into drawer_movements (drawer_session_id, kind, amount, reason)
  values (p_session_id, p_kind, p_amount, nullif(btrim(p_reason), ''))
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function record_drawer_movement(uuid, text, numeric, text) from public, anon;
grant execute on function record_drawer_movement(uuid, text, numeric, text) to authenticated;

-- 1. unclosed_days --------------------------------------------------------------------
drop function if exists unclosed_days(integer);
create or replace function unclosed_days(p_days integer default 31)
returns setof date
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_zone  text;
  v_today date;
  v_from  date;
begin
  perform require_staff();
  select time_zone into v_zone from settings where id;
  if v_zone is null then
    return;
  end if;
  v_today := shop_day(now());
  v_from := v_today - greatest(least(coalesce(p_days, 31), 366), 1) + 1;
  return query
  select d from (
    select v_today as d
    union select (sold_at at time zone v_zone)::date from sales
     where sold_at >= v_from::timestamp at time zone v_zone
    union select (refunded_at at time zone v_zone)::date from refunds
     where refunded_at >= v_from::timestamp at time zone v_zone
    union select business_day from drawer_sessions where business_day >= v_from
  ) days
   where d between v_from and v_today
     and not exists (select 1 from day_closes c where c.business_day = days.d and c.reopened_at is null)
   order by d;
end;
$$;
revoke all on function unclosed_days(integer) from public, anon;
grant execute on function unclosed_days(integer) to authenticated;
