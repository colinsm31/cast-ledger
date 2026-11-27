-- =============================================================================
-- 0110_paid_ins_and_outs.sql — cash put into or taken out of a drawer outside a
-- sale (AceStock, Phase 4B)
--
-- Adds:
--   1. drawer_movements (append-only): a paid-in (e.g. change brought from the
--      bank) or paid-out (e.g. stamps bought with drawer cash) on an open
--      drawer session, with an optional reason; who and when.
--   2. record_drawer_movement(session, kind, amount, reason) — only on an open
--      drawer, and a paid-out can't take more than the drawer should hold. A
--      reason is never required (0093).
--   3. drawer_cash_summary(session) gains paid_in and paid_out, and expected
--      cash counts them: float + cash taken − cash given back + paid-ins −
--      paid-outs. close_drawer saves that, unchanged.
--
-- Re-runnable.
-- =============================================================================

-- 1. drawer_movements -------------------------------------------------------------
create table if not exists drawer_movements (
  id                uuid primary key default gen_random_uuid(),
  drawer_session_id uuid not null references drawer_sessions (id),
  kind              text not null check (kind in ('paid_in', 'paid_out')),
  amount            numeric(12, 2) not null check (amount > 0),
  reason            text check (char_length(reason) <= 200),
  user_id           uuid default auth.uid() references profiles (id),
  created_at        timestamptz not null default now()
);
comment on table drawer_movements is 'Cash paid into or out of a drawer outside a sale; append-only (0110)';
create index if not exists idx_drawer_movements_session on drawer_movements (drawer_session_id);

alter table drawer_movements enable row level security;
drop policy if exists drawer_movements_staff_select on drawer_movements;
create policy drawer_movements_staff_select on drawer_movements for select to authenticated using (is_staff());
revoke all on drawer_movements from anon, authenticated;
grant select on drawer_movements to authenticated;

drop trigger if exists trg_enforce_staff_writer on drawer_movements;
create trigger trg_enforce_staff_writer before insert or update or delete on drawer_movements
  for each statement execute function enforce_staff_writer();

-- 3 (first, as record_drawer_movement uses it). drawer_cash_summary ------------
drop function if exists drawer_cash_summary(uuid);
create or replace function drawer_cash_summary(p_session_id uuid)
returns table (
  float_amount  numeric,
  cash_sales    numeric,
  cash_refunds  numeric,
  paid_in       numeric,
  paid_out      numeric,
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
  moved as (
    select m.kind, m.amount from drawer_movements m where m.drawer_session_id = p_session_id
  ),
  totals as (
    select ds.float_amount,
           coalesce((select sum(amount) from paid where method = 'cash'), 0) as cash_sales,
           coalesce((select sum(amount) from given_back where method = 'cash'), 0) as cash_refunds,
           coalesce((select sum(amount) from moved where kind = 'paid_in'), 0) as paid_in,
           coalesce((select sum(amount) from moved where kind = 'paid_out'), 0) as paid_out,
           coalesce((select sum(amount) from paid where method = 'check'), 0) as check_sales,
           coalesce((select sum(amount) from given_back where method = 'check'), 0) as check_refunds
      from drawer_sessions ds
     where ds.id = p_session_id
  )
  select t.float_amount, t.cash_sales, t.cash_refunds, t.paid_in, t.paid_out,
         t.float_amount + t.cash_sales - t.cash_refunds + t.paid_in - t.paid_out,
         t.check_sales, t.check_refunds
    from totals t;
$$;
revoke all on function drawer_cash_summary(uuid) from public, anon;
grant execute on function drawer_cash_summary(uuid) to authenticated;

-- 2. record_drawer_movement ---------------------------------------------------------
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

  -- A share lock: waits for a close in progress, and keeps the drawer open
  -- until this is recorded.
  select closed_at into v_closed_at from drawer_sessions where id = p_session_id for share;
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
