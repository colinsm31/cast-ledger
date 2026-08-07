-- =============================================================================
-- 0019_string_commit.sql — reserve/consume string stock for jobs (AceStock)
--
-- A string job reserves the string(s) it uses the moment it's entered, so other
-- jobs see it as unavailable ("set aside"). Nothing physically leaves inventory
-- until the job is marked complete, at which point the string is consumed.
--
--   committed(product)  = 1 per distinct catalog string on each *entered* job
--   available(product)  = on_hand − committed
--   complete a job      → post a 'consume' ledger txn (−1) per distinct string
--
-- Committed is derived from job status, so deleting an entered job releases its
-- reservation automatically. Re-runnable.
-- =============================================================================

-- 1. Allow a 'consume' inventory txn (string physically used on completion).
alter table inventory_txns drop constraint if exists inventory_txns_txn_type_check;
alter table inventory_txns
  add constraint inventory_txns_txn_type_check
  check (txn_type in ('receive', 'adjust', 'sell', 'transfer', 'consume'));

-- 2. Committed units per product: one per distinct catalog string on each job
--    that is still in the 'entered' state (union de-dups a single-string job
--    whose mains and crosses are the same product).
create or replace view string_committed as
select product_id, count(*)::int as committed
from (
  select id as job_id, main_product_id as product_id
    from string_jobs where status = 'entered' and main_product_id is not null
  union
  select id as job_id, cross_product_id as product_id
    from string_jobs where status = 'entered' and cross_product_id is not null
) x
group by product_id;

-- 3. Availability per product: on-hand minus committed.
create or replace view product_available as
select
  ps.product_id,
  ps.on_hand,
  coalesce(sc.committed, 0)              as committed,
  ps.on_hand - coalesce(sc.committed, 0) as available
from product_stock ps
left join string_committed sc on sc.product_id = ps.product_id;

grant select on string_committed to authenticated;
grant select on product_available to authenticated;

-- 4. On entered → complete, consume one unit of each distinct catalog string.
create or replace function advance_string_job(
  p_job_id        uuid,
  p_target_status text
)
returns text
language plpgsql
security invoker
as $$
declare
  v_current text;
  v_rank    integer;
  v_target  integer;
  v_main    uuid;
  v_cross   uuid;
begin
  select status, main_product_id, cross_product_id
    into v_current, v_main, v_cross
    from string_jobs where id = p_job_id;
  if v_current is null then
    raise exception 'Unknown string job %', p_job_id;
  end if;

  v_rank   := case v_current       when 'entered' then 0 when 'complete' then 1 when 'delivered' then 2 else -1 end;
  v_target := case p_target_status when 'entered' then 0 when 'complete' then 1 when 'delivered' then 2 else -1 end;

  if v_target < 0 then
    raise exception 'Invalid status "%"', p_target_status;
  end if;
  if v_target <> v_rank + 1 then
    raise exception 'Cannot move a string job from "%" to "%"', v_current, p_target_status;
  end if;

  update string_jobs
    set status       = p_target_status,
        completed_at = case when p_target_status = 'complete'  then now() else completed_at end,
        delivered_at = case when p_target_status = 'delivered' then now() else delivered_at end
  where id = p_job_id;

  -- Consume one unit of each distinct catalog string the job used.
  if p_target_status = 'complete' then
    insert into inventory_txns (txn_type, product_id, qty, note)
    select 'consume', pid, -1, 'String job completed'
    from (
      select distinct pid
      from (values (v_main), (v_cross)) as t(pid)
      where pid is not null
    ) d;
  end if;

  return p_target_status;
end;
$$;
grant execute on function advance_string_job(uuid, text) to authenticated;
