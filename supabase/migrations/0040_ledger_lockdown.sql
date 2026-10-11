-- =============================================================================
-- 0040_ledger_lockdown.sql — money history is write-only via server functions
--                            (AceStock, Phase 1C)
--
-- 1. Money and stock history can't be written directly. Sales, their lines,
--    payments, refunds, gift cards and their history, store credit history,
--    stock movements and racquet units are read-only to clients; every write
--    goes through a server function (record_sale, record_refund, receive_stock,
--    adjust_stock, receive_units, advance_string_job, cancel_string_job,
--    ensure_gift_card, add_store_credit, adjust_gift_card). Those functions now
--    run with the owner's rights (SECURITY DEFINER) so they can still write,
--    and only signed-in users may call them. Corrections are always new rows.
--
-- 2. String jobs: staff still create jobs and edit their strings, price, notes
--    and stringer directly, but status, payment, timestamps and attribution
--    only change through the server functions. New jobs must start "entered"
--    and are always attributed to the signed-in user who entered them.
--
-- 3. Views run with the reader's rights (security_invoker). They used to run
--    with the owner's, which bypassed row-level security: anyone with the
--    public anon key could list every gift card code and balance without
--    signing in. Signed-out users now have no access to tables, views or
--    functions at all (the app requires sign-in for everything).
--
-- 4. Every function pins search_path (public, then pg_temp last), so a caller
--    can't shadow a table the function uses.
--
-- Re-runnable.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- 1. Money and stock history: read-only to clients.
-- ----------------------------------------------------------------------------
do $$
declare
  tbl text;
  pol record;
begin
  foreach tbl in array array[
    'sales', 'sale_lines', 'sale_payments',
    'refunds', 'refund_lines', 'refund_payments',
    'gift_cards', 'gift_card_txns', 'store_credit_txns',
    'inventory_txns', 'product_units'
  ] loop
    execute format('revoke insert, update, delete, truncate on %I from authenticated, anon', tbl);

    -- Replace the old catch-all / insert policies with a single read policy.
    for pol in select policyname from pg_policies where schemaname = 'public' and tablename = tbl loop
      execute format('drop policy %I on %I', pol.policyname, tbl);
    end loop;
    execute format('create policy %I on %I for select to authenticated using (true)',
                   tbl || '_authenticated_select', tbl);
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 2. String jobs: clients edit the job's content, never its lifecycle.
-- ----------------------------------------------------------------------------
revoke update, delete, truncate on string_jobs from authenticated, anon;
grant update (
  main_product_id, main_brand, main_string, main_specs, main_tension,
  cross_product_id, cross_brand, cross_string, cross_specs, cross_tension,
  price, notes, strung_by
) on string_jobs to authenticated;

-- A job entered directly by a client starts fresh and belongs to the caller.
-- (Server functions and maintenance run as the owner and aren't constrained.)
create or replace function guard_new_string_job()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if current_user in ('authenticated', 'anon') then
    if new.status <> 'entered'
       or new.paid_sale_id is not null
       or new.completed_at is not null or new.completed_by is not null
       or new.delivered_at is not null or new.delivered_by is not null
       or new.cancelled_at is not null or new.cancelled_by is not null then
      raise exception 'A new string job starts as entered and unpaid';
    end if;
    new.entered_by := auth.uid();
    new.entered_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_new_string_job on string_jobs;
create trigger trg_guard_new_string_job
  before insert on string_jobs
  for each row execute function guard_new_string_job();

-- ----------------------------------------------------------------------------
-- 3. Views use the reader's permissions and row-level security.
-- ----------------------------------------------------------------------------
do $$
declare
  v text;
begin
  foreach v in array array[
    'product_stock', 'product_available', 'string_committed',
    'gift_card_balance', 'customer_store_credit'
  ] loop
    execute format('alter view %I set (security_invoker = true)', v);
    execute format('revoke all on %I from anon', v);
    execute format('grant select on %I to authenticated', v);
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 4. Functions: server functions that write money/stock history run as the
--    owner; every function pins search_path; signed-out users can call none.
-- ----------------------------------------------------------------------------
alter function record_sale(jsonb, uuid, jsonb, text)                 security definer;
alter function record_refund(uuid, jsonb, jsonb, text, text, text)   security definer;
alter function receive_stock(uuid, numeric, numeric, text, text)     security definer;
alter function adjust_stock(uuid, numeric, text)                     security definer;
alter function receive_units(uuid, jsonb)                            security definer;
alter function advance_string_job(uuid, text)                        security definer;
alter function cancel_string_job(uuid)                               security definer;
alter function ensure_gift_card(text, uuid)                          security definer;
alter function add_store_credit(uuid, numeric, text)                 security definer;
alter function adjust_gift_card(uuid, numeric, text)                 security definer;

do $$
declare
  fn record;
begin
  for fn in
    select p.oid::regprocedure as signature, p.prorettype = 'trigger'::regtype as is_trigger
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prokind = 'f'
  loop
    execute format('alter function %s set search_path = public, pg_temp', fn.signature);
    execute format('revoke all on function %s from public, anon', fn.signature);
    if fn.is_trigger then
      -- Trigger functions only run as triggers, never as API calls.
      execute format('revoke all on function %s from authenticated', fn.signature);
    else
      execute format('grant execute on function %s to authenticated', fn.signature);
    end if;
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 5. Signed-out users get nothing, now and for objects created later.
--    (Row-level security already returned no rows to anon; this removes the
--    underlying grants too.)
-- ----------------------------------------------------------------------------
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from anon, public;
