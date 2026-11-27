-- =============================================================================
-- 0108_drawer_sessions.sql — cash drawers opened with a float and closed with a
-- count (AceStock, Phase 4B)
--
-- Adds:
--   1. settings.time_zone — the shop's time zone, set by an admin in Settings.
--      A drawer's business day (and, later, the day close) is counted in it.
--   2. drawers — the shop's named cash drawers (admins add and rename them;
--      everyone signed in reads them). One "Main drawer" to start.
--   3. drawer_sessions — one drawer from open to close: the starting float and
--      the closing count, each counted by denomination; who and when. One open
--      session per drawer at a time.
--   4. drawer_count_total(counts) — what a denomination count adds up to, and
--      a check that it's well formed. Counts are a JSON object of
--      "100" "50" "20" "10" "5" "1" "0.25" "0.10" "0.05" "0.01" → how many
--      (whole numbers), plus "other" → an amount (rolled coin and the like).
--   5. open_drawer(drawer, counts) / close_drawer(session, counts, note).
--
-- Staff read drawers and sessions; sessions change only through the two
-- functions. Re-runnable.
-- =============================================================================

-- 1. Shop time zone -------------------------------------------------------------
alter table settings add column if not exists time_zone text;
comment on column settings.time_zone is
  'The shop''s time zone (e.g. America/Chicago); business days are counted in it (0108). Null until an admin sets it';

create or replace function is_time_zone(p_name text)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select exists (select 1 from pg_timezone_names where name = p_name);
$$;
revoke all on function is_time_zone(text) from public, anon;
grant execute on function is_time_zone(text) to authenticated;

-- A check constraint can't run a query, so a trigger checks the name.
create or replace function check_settings_time_zone()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.time_zone is not null and not is_time_zone(new.time_zone) then
    raise exception 'Unknown time zone: %', new.time_zone using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function check_settings_time_zone() from public, anon, authenticated;

drop trigger if exists trg_settings_time_zone on settings;
create trigger trg_settings_time_zone before insert or update of time_zone on settings
  for each row execute function check_settings_time_zone();

-- The shop's business day for a moment; refuses until the time zone is set.
create or replace function shop_day(p_at timestamptz)
returns date
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_zone text;
begin
  select time_zone into v_zone from settings where id;
  if v_zone is null then
    raise exception 'An admin needs to set the shop''s time zone in Settings first'
      using errcode = '22023';
  end if;
  return (p_at at time zone v_zone)::date;
end;
$$;
revoke all on function shop_day(timestamptz) from public, anon;
grant execute on function shop_day(timestamptz) to authenticated;

-- 2. Drawers --------------------------------------------------------------------
create table if not exists drawers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(btrim(name)) between 1 and 50),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
comment on table drawers is 'The shop''s named cash drawers (0108)';
create unique index if not exists uq_drawers_name on drawers (lower(btrim(name)));

alter table drawers enable row level security;
drop policy if exists drawers_staff_select on drawers;
drop policy if exists drawers_admin_insert on drawers;
drop policy if exists drawers_admin_update on drawers;
create policy drawers_staff_select on drawers for select to authenticated using (is_staff());
create policy drawers_admin_insert on drawers for insert to authenticated with check (is_admin());
create policy drawers_admin_update on drawers for update to authenticated using (is_admin()) with check (is_admin());
revoke all on drawers from anon, authenticated;
grant select, insert, update (name, is_active) on drawers to authenticated;

drop trigger if exists trg_enforce_staff_writer on drawers;
create trigger trg_enforce_staff_writer before insert or update or delete on drawers
  for each statement execute function enforce_staff_writer();

insert into drawers (name)
select 'Main drawer' where not exists (select 1 from drawers);

-- 3. Drawer sessions ------------------------------------------------------------
create table if not exists drawer_sessions (
  id              uuid primary key default gen_random_uuid(),
  drawer_id       uuid not null references drawers (id),
  business_day    date not null,
  opened_at       timestamptz not null default now(),
  opened_by       uuid default auth.uid() references profiles (id),
  float_counts    jsonb not null,
  float_amount    numeric(12, 2) not null check (float_amount >= 0),
  closed_at       timestamptz,
  closed_by       uuid references profiles (id),
  counted_counts  jsonb,
  counted_cash    numeric(12, 2) check (counted_cash >= 0),
  close_note      text check (char_length(close_note) <= 500),
  constraint ck_drawer_sessions_closed check (
    (closed_at is null and counted_counts is null and counted_cash is null and closed_by is null)
    or (closed_at is not null and counted_counts is not null and counted_cash is not null)
  )
);
comment on table drawer_sessions is 'A cash drawer from open (float) to close (count), by denomination (0108)';
create unique index if not exists uq_drawer_sessions_open on drawer_sessions (drawer_id) where closed_at is null;
create index if not exists idx_drawer_sessions_day on drawer_sessions (business_day);

alter table drawer_sessions enable row level security;
drop policy if exists drawer_sessions_staff_select on drawer_sessions;
create policy drawer_sessions_staff_select on drawer_sessions for select to authenticated using (is_staff());
revoke all on drawer_sessions from anon, authenticated;
grant select on drawer_sessions to authenticated;

drop trigger if exists trg_enforce_staff_writer on drawer_sessions;
create trigger trg_enforce_staff_writer before insert or update or delete on drawer_sessions
  for each statement execute function enforce_staff_writer();

-- 4. drawer_count_total -----------------------------------------------------------
create or replace function drawer_count_total(p_counts jsonb)
returns numeric
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_key   text;
  v_value jsonb;
  v_total numeric := 0;
begin
  if p_counts is null or jsonb_typeof(p_counts) <> 'object' then
    raise exception 'Count the drawer by denomination' using errcode = '22023';
  end if;
  for v_key, v_value in select key, value from jsonb_each(p_counts) loop
    if jsonb_typeof(v_value) <> 'number' or (v_value #>> '{}')::numeric < 0 then
      raise exception 'Each count must be a number of 0 or more' using errcode = '22023';
    end if;
    if v_key = 'other' then
      if (v_value #>> '{}')::numeric <> round((v_value #>> '{}')::numeric, 2) then
        raise exception 'Other cash must be in dollars and cents' using errcode = '22023';
      end if;
      v_total := v_total + (v_value #>> '{}')::numeric;
    elsif v_key in ('100', '50', '20', '10', '5', '1', '0.25', '0.10', '0.05', '0.01') then
      if (v_value #>> '{}')::numeric <> trunc((v_value #>> '{}')::numeric) then
        raise exception 'Count whole bills and coins' using errcode = '22023';
      end if;
      v_total := v_total + v_key::numeric * (v_value #>> '{}')::numeric;
    else
      raise exception 'Unknown denomination: %', v_key using errcode = '22023';
    end if;
  end loop;
  if v_total > 999999 then
    raise exception 'That count is too large' using errcode = '22023';
  end if;
  return round(v_total, 2);
end;
$$;
revoke all on function drawer_count_total(jsonb) from public, anon;
grant execute on function drawer_count_total(jsonb) to authenticated;

-- 5. open_drawer / close_drawer ---------------------------------------------------
create or replace function open_drawer(p_drawer_id uuid, p_counts jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_drawer drawers%rowtype;
  v_id     uuid;
begin
  perform require_staff();
  select * into v_drawer from drawers where id = p_drawer_id for update;
  if not found then
    raise exception 'Drawer not found' using errcode = 'P0002';
  end if;
  if not v_drawer.is_active then
    raise exception '% isn''t in use', v_drawer.name using errcode = '22023';
  end if;
  if exists (select 1 from drawer_sessions where drawer_id = p_drawer_id and closed_at is null) then
    raise exception '% is already open', v_drawer.name using errcode = '23505';
  end if;

  insert into drawer_sessions (drawer_id, business_day, float_counts, float_amount)
  values (p_drawer_id, shop_day(now()), p_counts, drawer_count_total(p_counts))
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function open_drawer(uuid, jsonb) from public, anon;
grant execute on function open_drawer(uuid, jsonb) to authenticated;

create or replace function close_drawer(p_session_id uuid, p_counts jsonb, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_session drawer_sessions%rowtype;
begin
  perform require_staff();
  select * into v_session from drawer_sessions where id = p_session_id for update;
  if not found then
    raise exception 'Drawer session not found' using errcode = 'P0002';
  end if;
  if v_session.closed_at is not null then
    raise exception 'This drawer has already been closed' using errcode = '22023';
  end if;

  update drawer_sessions
     set closed_at = now(),
         closed_by = auth.uid(),
         counted_counts = p_counts,
         counted_cash = drawer_count_total(p_counts),
         close_note = nullif(btrim(p_note), '')
   where id = p_session_id;
end;
$$;
revoke all on function close_drawer(uuid, jsonb, text) from public, anon;
grant execute on function close_drawer(uuid, jsonb, text) to authenticated;
