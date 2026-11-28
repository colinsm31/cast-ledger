-- =============================================================================
-- 0109_cash_to_drawer.sql — cash taken or given back goes to a drawer;
-- expected vs counted at close (AceStock, Phase 4B)
--
-- Adds:
--   1. settings.cash_needs_drawer (on): cash can't be taken or given back
--      unless the register's drawer is open. Card, check, gift card and store
--      credit work either way.
--   2. sales.drawer_session_id / refunds.drawer_session_id, filled when the
--      row is written (so record_sale, record_refund, record_exchange and
--      change_paid_string_job are unchanged): the open session of the drawer
--      the register names in its x-acestock-drawer request header, or else
--      the only open session, if there's exactly one.
--   3. A check on each cash payment and cash refund that its sale or refund
--      has a drawer (when cash_needs_drawer is on), saying what to do if not.
--   4. drawer_cash_summary(session): the float, cash taken and given back,
--      the cash expected in the drawer, and checks taken and given back.
--   5. drawer_sessions.expected_cash, saved by close_drawer, so over/short
--      (counted − expected) stays as it was at the close.
--
-- Re-runnable.
-- =============================================================================

-- 1. Setting --------------------------------------------------------------------
alter table settings add column if not exists cash_needs_drawer boolean not null default true;
comment on column settings.cash_needs_drawer is
  'Cash can only be taken or given back while the register''s drawer is open (0109)';

-- 2. Which drawer a sale or refund's cash goes to --------------------------------
alter table sales   add column if not exists drawer_session_id uuid references drawer_sessions (id);
alter table refunds add column if not exists drawer_session_id uuid references drawer_sessions (id);
create index if not exists idx_sales_drawer_session on sales (drawer_session_id);
create index if not exists idx_refunds_drawer_session on refunds (drawer_session_id);
comment on column sales.drawer_session_id is 'The drawer session open at the register when the sale was rung (0109)';
comment on column refunds.drawer_session_id is 'The drawer session open at the register when the refund was given (0109)';

-- The drawer the register named in its request, if any (a uuid, or null).
create or replace function requested_drawer_id()
returns uuid
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_value text;
begin
  v_value := nullif(current_setting('request.headers', true), '')::json ->> 'x-acestock-drawer';
  if v_value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return v_value::uuid;
  end if;
  return null;
end;
$$;
revoke all on function requested_drawer_id() from public, anon, authenticated;

-- The open session the register's cash goes to: its named drawer's, else the
-- only one open; null if neither. The session is locked (key share) until the
-- sale or refund commits, so a close running at the same moment either waits
-- for it (and counts it) or finishes first (and the session is no longer open).
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
  if v_drawer is not null then
    select array_agg(id) into v_ids
      from (select id from drawer_sessions where drawer_id = v_drawer and closed_at is null for key share) s;
  else
    select array_agg(id) into v_ids
      from (select id from drawer_sessions where closed_at is null limit 2 for key share) s;
  end if;
  return case when cardinality(v_ids) = 1 then v_ids[1] end;
end;
$$;
revoke all on function register_drawer_session() from public, anon, authenticated;

create or replace function set_drawer_session()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.drawer_session_id := coalesce(new.drawer_session_id, register_drawer_session());
  return new;
end;
$$;
revoke all on function set_drawer_session() from public, anon, authenticated;

drop trigger if exists trg_sales_drawer_session on sales;
create trigger trg_sales_drawer_session before insert on sales
  for each row execute function set_drawer_session();
drop trigger if exists trg_refunds_drawer_session on refunds;
create trigger trg_refunds_drawer_session before insert on refunds
  for each row execute function set_drawer_session();

-- 3. Cash needs a drawer ------------------------------------------------------------
create or replace function check_cash_drawer()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_session uuid;
  v_action  text;
  v_drawer  drawers%rowtype;
  v_open    integer;
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

  select * into v_drawer from drawers where id = requested_drawer_id();
  if found then
    raise exception 'Open % on the Cash drawer screen before %', v_drawer.name, v_action using errcode = '22023';
  end if;
  select count(*) into v_open from drawer_sessions where closed_at is null;
  if v_open > 1 then
    raise exception 'Choose this register''s drawer on the Cash drawer screen before %', v_action using errcode = '22023';
  end if;
  raise exception 'Open the cash drawer on the Cash drawer screen before %', v_action using errcode = '22023';
end;
$$;
revoke all on function check_cash_drawer() from public, anon, authenticated;

drop trigger if exists trg_sale_payments_cash_drawer on sale_payments;
create trigger trg_sale_payments_cash_drawer before insert on sale_payments
  for each row execute function check_cash_drawer();
drop trigger if exists trg_refund_payments_cash_drawer on refund_payments;
create trigger trg_refund_payments_cash_drawer before insert on refund_payments
  for each row execute function check_cash_drawer();

-- 4. drawer_cash_summary ------------------------------------------------------------
drop function if exists drawer_cash_summary(uuid);
create or replace function drawer_cash_summary(p_session_id uuid)
returns table (
  float_amount  numeric,
  cash_sales    numeric,
  cash_refunds  numeric,
  expected_cash numeric,
  check_sales   numeric,
  check_refunds numeric
)
language sql
stable
set search_path = public, pg_temp
as $$
  with paid as (
    select sp.method, sp.amount
      from sale_payments sp join sales s on s.id = sp.sale_id
     where s.drawer_session_id = p_session_id and sp.method in ('cash', 'check')
  ),
  given_back as (
    select rp.method, rp.amount
      from refund_payments rp join refunds r on r.id = rp.refund_id
     where r.drawer_session_id = p_session_id and rp.method in ('cash', 'check')
  ),
  totals as (
    select ds.float_amount,
           coalesce((select sum(amount) from paid where method = 'cash'), 0) as cash_sales,
           coalesce((select sum(amount) from given_back where method = 'cash'), 0) as cash_refunds,
           coalesce((select sum(amount) from paid where method = 'check'), 0) as check_sales,
           coalesce((select sum(amount) from given_back where method = 'check'), 0) as check_refunds
      from drawer_sessions ds
     where ds.id = p_session_id
  )
  select t.float_amount, t.cash_sales, t.cash_refunds,
         t.float_amount + t.cash_sales - t.cash_refunds,
         t.check_sales, t.check_refunds
    from totals t;
$$;
revoke all on function drawer_cash_summary(uuid) from public, anon;
grant execute on function drawer_cash_summary(uuid) to authenticated;

-- 5. Expected cash saved at the close -------------------------------------------------
alter table drawer_sessions add column if not exists expected_cash numeric(12, 2);
comment on column drawer_sessions.expected_cash is
  'Cash the drawer should have held at the close: float + cash taken − cash given back (0109)';

-- close_drawer — same as 0108, and saves the expected cash.
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
         expected_cash = (select s.expected_cash from drawer_cash_summary(p_session_id) s),
         close_note = nullif(btrim(p_note), '')
   where id = p_session_id;
end;
$$;
revoke all on function close_drawer(uuid, jsonb, text) from public, anon;
grant execute on function close_drawer(uuid, jsonb, text) to authenticated;
