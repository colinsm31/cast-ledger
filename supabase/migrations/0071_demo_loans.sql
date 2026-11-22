-- =============================================================================
-- 0071_demo_loans.sql — lend a demo frame to a customer and check it back in
-- (AceStock, Phase 3C)
--
-- Before:
--   • A frame could be moved to the demo fleet (0067), but nothing recorded
--     who had it, when it was due back, or what the shop was holding for it.
--
-- Now:
--   1. demo_loans: each time a demo frame goes out — a loan number (D1001
--      on), the frame, the customer, when it went out and is due back, a
--      deposit note ("card on file", "$50 cash held": a note only, no money
--      is taken), who lent it and, once back, who checked it in and whether
--      it went back to the demo fleet or was retired. One open loan per
--      frame. Read-only for staff.
--   2. settings.demo_loan_days (default 3, 1–60): when a loan is due back
--      unless staff pick a time.
--   3. check_out_demo(unit, customer, due, deposit note, note): lends a frame
--      in the demo fleet. The frame becomes 'assigned' to the customer, and
--      its history (0067) says who it was lent to and the loan number.
--   4. check_in_demo(loan, status, reason): the frame goes back to the demo
--      fleet, or is retired (with a reason) if it came back damaged.
--   5. set_demo_due(loan, due): a new due time for a loan that's still out.
--      A due time is in the future and at most 90 days away.
--
-- All three are owner rights, staff only, and lock the frame or loan.
-- Re-runnable.
-- =============================================================================

alter table settings add column if not exists demo_loan_days integer not null default 3;
alter table settings drop constraint if exists ck_settings_demo_loan_days;
alter table settings add constraint ck_settings_demo_loan_days check (demo_loan_days between 1 and 60);
comment on column settings.demo_loan_days is 'How many days a demo loan lasts, unless staff pick a time';

create table if not exists demo_loans (
  id              uuid primary key default gen_random_uuid(),
  loan_number     bigint generated always as identity (start with 1001),
  product_unit_id uuid not null references product_units (id),
  customer_id     uuid not null references customers (id),
  out_at          timestamptz not null default now(),
  out_by          uuid references profiles (id),
  due_back_at     timestamptz not null,
  deposit_note    text check (char_length(deposit_note) <= 200),
  note            text check (char_length(note) <= 200),
  back_at         timestamptz,
  back_by         uuid references profiles (id),
  back_status     text check (back_status in ('demo', 'retired')),
  back_reason     text check (char_length(back_reason) <= 200),
  constraint ck_demo_loans_back check ((back_at is null) = (back_status is null))
);
comment on table demo_loans is 'Each time a demo frame was lent to a customer';
create unique index if not exists uq_demo_loans_loan_number on demo_loans (loan_number);
create unique index if not exists uq_demo_loans_open_unit on demo_loans (product_unit_id) where back_at is null;
create index if not exists ix_demo_loans_customer on demo_loans (customer_id, out_at desc);
create index if not exists ix_demo_loans_open_due on demo_loans (due_back_at) where back_at is null;

alter table demo_loans enable row level security;
drop policy if exists demo_loans_staff_select on demo_loans;
create policy demo_loans_staff_select on demo_loans
  for select to authenticated using (is_staff());
revoke all on demo_loans from anon;
revoke insert, update, delete, truncate on demo_loans from authenticated;
grant select on demo_loans to authenticated;

-- -----------------------------------------------------------------------------
-- demo_due_problem — why a due time can't be used (null if it can)
-- -----------------------------------------------------------------------------
create or replace function demo_due_problem(p_due timestamptz)
returns text
language sql
stable
set search_path = public, pg_temp
as $$
  select case
    when p_due is null then 'Pick when the demo is due back'
    when p_due <= now() then 'The due time has to be in the future'
    when p_due > now() + interval '90 days' then 'A demo can be lent for at most 90 days'
  end;
$$;

revoke all on function demo_due_problem(timestamptz) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- check_out_demo — lend a demo frame to a customer
-- -----------------------------------------------------------------------------
create or replace function check_out_demo(
  p_unit_id      uuid,
  p_customer_id  uuid,
  p_due_back_at  timestamptz default null,
  p_deposit_note text default null,
  p_note         text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status   text;
  v_name     text;
  v_due      timestamptz;
  v_deposit  text := nullif(btrim(coalesce(p_deposit_note, '')), '');
  v_note     text := nullif(btrim(coalesce(p_note, '')), '');
  v_problem  text;
  v_loan     demo_loans%rowtype;
begin
  perform require_staff();

  select btrim(concat_ws(' ', first_name, last_name)) into v_name from customers where id = p_customer_id;
  if not found then
    raise exception 'Pick the customer borrowing the demo';
  end if;
  if char_length(coalesce(v_deposit, '')) > 200 or char_length(coalesce(v_note, '')) > 200 then
    raise exception 'Keep each note to 200 characters';
  end if;

  v_due := coalesce(p_due_back_at,
                    now() + make_interval(days => coalesce((select demo_loan_days from settings where id), 3)));
  v_problem := demo_due_problem(v_due);
  if v_problem is not null then
    raise exception '%', v_problem;
  end if;

  select status into v_status from product_units where id = p_unit_id for update;
  if not found then
    raise exception 'Unknown unit %', p_unit_id;
  end if;
  if v_status = 'assigned' then
    raise exception 'This frame is already out on demo';
  end if;
  if v_status <> 'demo' then
    raise exception 'Only a frame in the demo fleet can be lent (this one is %)', replace(v_status, '_', ' ');
  end if;

  insert into demo_loans (product_unit_id, customer_id, due_back_at, deposit_note, note, out_by)
  values (p_unit_id, p_customer_id, v_due, v_deposit, v_note, auth.uid())
  returning * into v_loan;

  perform set_config('acestock.unit_status_reason',
                     format('Lent to %s (D%s)', coalesce(nullif(v_name, ''), 'a customer'), v_loan.loan_number), true);
  update product_units set status = 'assigned', customer_id = p_customer_id, updated_at = now() where id = p_unit_id;
  perform set_config('acestock.unit_status_reason', '', true);
  return v_loan.id;
end;
$$;

revoke all on function check_out_demo(uuid, uuid, timestamptz, text, text) from public, anon;
grant execute on function check_out_demo(uuid, uuid, timestamptz, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- check_in_demo — a lent frame comes back
-- -----------------------------------------------------------------------------
create or replace function check_in_demo(
  p_loan_id uuid,
  p_status  text default 'demo',
  p_reason  text default null
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_loan   demo_loans%rowtype;
  v_status text := coalesce(nullif(p_status, ''), 'demo');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform require_staff();

  if v_status not in ('demo', 'retired') then
    raise exception 'A demo comes back to the demo fleet or is retired (not "%")', v_status;
  end if;
  if v_status = 'retired' and v_reason is null then
    raise exception 'Say why the frame is retired';
  end if;
  if char_length(coalesce(v_reason, '')) > 200 then
    raise exception 'Keep the reason to 200 characters';
  end if;

  select * into v_loan from demo_loans where id = p_loan_id for update;
  if not found then
    raise exception 'Unknown demo loan %', p_loan_id;
  end if;
  if v_loan.back_at is not null then
    raise exception 'Demo D% has already been checked in', v_loan.loan_number;
  end if;
  perform 1 from product_units where id = v_loan.product_unit_id for update;

  update demo_loans
     set back_at = now(), back_by = auth.uid(), back_status = v_status, back_reason = v_reason
   where id = p_loan_id;

  perform set_config('acestock.unit_status_reason',
                     coalesce(v_reason || format(' (back from D%s)', v_loan.loan_number),
                              format('Back from D%s', v_loan.loan_number)), true);
  update product_units set status = v_status, customer_id = null, updated_at = now() where id = v_loan.product_unit_id;
  perform set_config('acestock.unit_status_reason', '', true);
  return v_status;
end;
$$;

revoke all on function check_in_demo(uuid, text, text) from public, anon;
grant execute on function check_in_demo(uuid, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- set_demo_due — a new due time for a loan still out
-- -----------------------------------------------------------------------------
create or replace function set_demo_due(p_loan_id uuid, p_due_back_at timestamptz)
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_loan    demo_loans%rowtype;
  v_problem text := demo_due_problem(p_due_back_at);
begin
  perform require_staff();
  if v_problem is not null then
    raise exception '%', v_problem;
  end if;

  select * into v_loan from demo_loans where id = p_loan_id for update;
  if not found then
    raise exception 'Unknown demo loan %', p_loan_id;
  end if;
  if v_loan.back_at is not null then
    raise exception 'Demo D% has already been checked in', v_loan.loan_number;
  end if;

  update demo_loans set due_back_at = p_due_back_at where id = p_loan_id;
  return p_due_back_at;
end;
$$;

revoke all on function set_demo_due(uuid, timestamptz) from public, anon;
grant execute on function set_demo_due(uuid, timestamptz) to authenticated;
