-- =============================================================================
-- 0091_new_job_locks_racquet_first.sql — a new job reads its racquet's owner
-- with the racquet locked (AceStock, Phase 3E review #4; second review #7)
--
-- Before (0080, 0084):
--   A new string job's triggers run in name order. guard_active_customer
--   (trg_guard_active_customer) read the racquet's owner without a lock, and
--   only then did guard_string_job_racket (trg_guard_string_job_racket, 0042)
--   lock the racquet. If the racquet was being moved to an inactive customer
--   at that moment, the check saw the old, active owner, then waited for the
--   move, and the job was entered under the inactive customer. Race 19 only
--   tried the other order (the job first), which was already safe.
--
-- Now: guard_active_customer locks the racquet (for update, the same lock the
-- racquet guard takes next, so two new jobs queue rather than deadlock)
-- before reading its owner. A move that started first is waited for, and the
-- new owner is the one checked. Race 21 starts the move first.
--
-- Re-runnable.
-- =============================================================================

create or replace function guard_active_customer()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_customer uuid;
  v_use      text;
  v_name     text;
  v_active   boolean;
begin
  case tg_table_name
    when 'sales' then
      v_customer := new.customer_id;
      v_use := 'be put on a sale';
    when 'demo_loans' then
      v_customer := new.customer_id;
      v_use := 'borrow a demo';
    when 'store_credit_txns' then
      v_customer := new.customer_id;
      v_use := 'use store credit';
    when 'string_jobs' then
      -- The racquet is locked first, so a move to another customer that is
      -- under way finishes before its owner is read (0091).
      select customer_id into v_customer from customer_rackets where id = new.customer_racket_id for update;
      v_use := 'have a new string job';
  end case;
  -- A share lock waits for set_customer_active (which locks the customer for
  -- update) and then reads what it saved; it also makes a deactivation that
  -- starts now wait for this row, so its open-job and demo checks see it.
  select is_active, first_name || ' ' || last_name into v_active, v_name
    from customers where id = v_customer
    for share;
  if found and not v_active then
    raise exception '% is inactive, so they can''t %: make them active again first', v_name, v_use;
  end if;
  return new;
end;
$$;
revoke all on function guard_active_customer() from public, anon, authenticated;
