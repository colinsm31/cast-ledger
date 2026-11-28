-- =============================================================================
-- 0113_drawer_review_fixes.sql — drawer fixes from the 4B review (AceStock)
--
--   1. A register's drawer counts only while it's a drawer in use: a drawer id
--      that's out of use, or no longer exists, is ignored (review 1).
--   2. A register that names no drawer only falls back to an open drawer when
--      the shop has just one drawer in use, so its cash can't land in another
--      register's drawer (review 3).
--   3. A drawer can't be taken out of use while it's open, so it can always be
--      counted and closed, and the day closed (review 2).
--   4. Paid-ins and paid-outs take the drawer one at a time (a no-key-update
--      lock: sales still go on), so two paid-outs at once can't both pass the
--      "enough cash" check (review 11).
--
-- register_drawer_session and check_cash_drawer are as in 0109 except where
-- marked; record_drawer_movement as in 0110 except its lock. Re-runnable.
-- =============================================================================

-- The drawer the register names, if it's a drawer in use (review 1).
create or replace function requested_drawer_id()
returns uuid
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_value text;
  v_id    uuid;
begin
  v_value := nullif(current_setting('request.headers', true), '')::json ->> 'x-acestock-drawer';
  if v_value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return null;
  end if;
  select id into v_id from drawers where id = v_value::uuid and is_active;
  return v_id;
end;
$$;
revoke all on function requested_drawer_id() from public, anon, authenticated;

-- The open session the register's cash goes to: its named drawer's, else the
-- only drawer in use's (review 2); null if neither. Locked as in 0109.
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
  if new.method <> 'cash' or not coalesce((select cash_needs_drawer from settings where id), false) then
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
    raise exception 'Open % on the Cash drawer screen before %', v_drawer.name, v_action using errcode = '22023';
  end if;
  if exists (select 1 from drawers where is_active) then
    raise exception 'Choose this register''s drawer on the Cash drawer screen before %', v_action using errcode = '22023';
  end if;
  raise exception 'Add a cash drawer in Settings before %', v_action using errcode = '22023';
end;
$$;
revoke all on function check_cash_drawer() from public, anon, authenticated;

-- 3. A drawer stays in use while it's open (review 2).
create or replace function guard_open_drawer_in_use()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if old.is_active and not new.is_active
     and exists (select 1 from drawer_sessions where drawer_id = new.id and closed_at is null) then
    raise exception 'Count and close % before taking it out of use', new.name using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function guard_open_drawer_in_use() from public, anon, authenticated;

drop trigger if exists trg_drawers_open_in_use on drawers;
create trigger trg_drawers_open_in_use before update of is_active on drawers
  for each row execute function guard_open_drawer_in_use();

-- 4. record_drawer_movement — same as 0110, with a no-key-update lock.
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

  -- One paid-in or paid-out at a time per drawer (review 11), and none while
  -- it's being closed; sales (key share) aren't held up.
  select closed_at into v_closed_at from drawer_sessions where id = p_session_id for no key update;
  if not found then
    raise exception 'Drawer session not found' using errcode = 'P0002';
  end if;
  if v_closed_at is not null then
    raise exception 'This drawer has been closed' using errcode = '22023';
  end if;
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
