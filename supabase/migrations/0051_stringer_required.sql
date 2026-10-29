-- =============================================================================
-- 0051_stringer_required.sql — a job needs a stringer to be marked complete
--                              (AceStock, polish review #7)
--
-- Before:
--   • The string job page only enabled "Mark complete" once a stringer was
--     picked, but the server didn't check: a direct call, or a stringer save
--     that failed or was overtaken, could complete a job with no stringer.
--
-- Now:
--   1. advance_string_job refuses entered → complete until the job has a
--      stringer (strung_by, not blank). Everything else is as 0042: explicit
--      transitions, row lock, paid before delivery, owner rights, staff only.
--
-- Jobs already complete or delivered without a stringer are left as they are.
-- Re-runnable.
-- =============================================================================

-- advance_string_job — same as 0042, plus: a stringer before 'complete'.
create or replace function advance_string_job(
  p_job_id        uuid,
  p_target_status text
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_current text;
  v_main    uuid;
  v_cross   uuid;
  v_paid    uuid;
  v_strung  text;
begin
  perform require_staff();

  if p_target_status is null
     or p_target_status not in ('entered', 'complete', 'delivered', 'cancelled') then
    raise exception 'Invalid status "%"', p_target_status;
  end if;

  -- Lock the job so a second click (or register) waits, then sees this one's result.
  select status, main_product_id, cross_product_id, paid_sale_id, strung_by
    into v_current, v_main, v_cross, v_paid, v_strung
    from string_jobs where id = p_job_id
    for update;
  if not found then
    raise exception 'Unknown string job %', p_job_id;
  end if;

  if (v_current, p_target_status) not in (('entered', 'complete'), ('complete', 'delivered')) then
    raise exception 'Cannot move a string job from "%" to "%"', v_current, p_target_status;
  end if;
  if p_target_status = 'delivered' and v_paid is null then
    raise exception 'Take payment for this string job before marking it delivered';
  end if;
  if p_target_status = 'complete' and coalesce(trim(v_strung), '') = '' then
    raise exception 'Record who strung it before marking it complete';
  end if;

  update string_jobs
    set status       = p_target_status,
        completed_at = case when p_target_status = 'complete'  then now()      else completed_at end,
        completed_by = case when p_target_status = 'complete'  then auth.uid() else completed_by end,
        delivered_at = case when p_target_status = 'delivered' then now()      else delivered_at end,
        delivered_by = case when p_target_status = 'delivered' then auth.uid() else delivered_by end
  where id = p_job_id
    and status = v_current;

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

revoke all on function advance_string_job(uuid, text) from public, anon;
grant execute on function advance_string_job(uuid, text) to authenticated;
