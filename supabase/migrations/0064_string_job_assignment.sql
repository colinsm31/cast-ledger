-- =============================================================================
-- 0064_string_job_assignment.sql — assign string jobs to a stringer
-- (AceStock, Phase 3A)
--
-- Before:
--   • Who strung a job (strung_by) was only recorded when it was finished, so
--     the queue couldn't show who a waiting job was meant for.
--
-- Now:
--   1. string_jobs.assigned_to: the stringer a waiting job is assigned to, by
--      the same names as strung_by (the 'stringer' list). It can change while
--      the job waits to be strung, never after; blank means unassigned.
--   2. advance_string_job: marking a job complete with no stringer recorded
--      records the one it was assigned to. Otherwise it's as 0051: explicit
--      transitions, row lock, a stringer before 'complete', paid before
--      delivery, owner rights, staff only.
--
-- Re-runnable.
-- =============================================================================

alter table string_jobs add column if not exists assigned_to text;
alter table string_jobs drop constraint if exists ck_string_jobs_assigned_to;
alter table string_jobs add constraint ck_string_jobs_assigned_to
  check (assigned_to = trim(assigned_to) and char_length(assigned_to) between 1 and 60);
comment on column string_jobs.assigned_to is 'The stringer a waiting job is assigned to (null = unassigned)';

grant update (assigned_to) on string_jobs to authenticated;

-- -----------------------------------------------------------------------------
-- guard_string_job_assignment — tidy the name; fixed once strung
-- -----------------------------------------------------------------------------
create or replace function guard_string_job_assignment()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.assigned_to := nullif(trim(new.assigned_to), '');
  if tg_op = 'UPDATE'
     and new.assigned_to is distinct from old.assigned_to
     and old.status <> 'entered'
     and current_user in ('authenticated', 'anon') then
    raise exception 'The racquet has been strung, so who it''s assigned to can''t change';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_string_job_assignment on string_jobs;
create trigger trg_string_job_assignment
  before insert or update of assigned_to on string_jobs
  for each row execute function guard_string_job_assignment();

-- -----------------------------------------------------------------------------
-- advance_string_job — same as 0051, plus: the assigned stringer by default
-- -----------------------------------------------------------------------------
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
  v_current  text;
  v_main     uuid;
  v_cross    uuid;
  v_paid     uuid;
  v_strung   text;
begin
  perform require_staff();

  if p_target_status is null
     or p_target_status not in ('entered', 'complete', 'delivered', 'cancelled') then
    raise exception 'Invalid status "%"', p_target_status;
  end if;

  -- Lock the job so a second click (or register) waits, then sees this one's result.
  select status, main_product_id, cross_product_id, paid_sale_id,
         coalesce(nullif(trim(strung_by), ''), assigned_to)
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
        strung_by    = case when p_target_status = 'complete'  then v_strung   else strung_by end,
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
