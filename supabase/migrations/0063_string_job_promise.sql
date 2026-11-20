-- =============================================================================
-- 0063_string_job_promise.sql — promised time and rush on string jobs
-- (AceStock, Phase 3A)
--
-- Before:
--   • A string job had no due time. The open queue was in drop-off order, so a
--     job promised for this afternoon looked the same as one due next week.
--
-- Now:
--   1. string_jobs.promised_at: when the customer was told it would be ready.
--      A new job without one is promised settings.stringing_turnaround_hours
--      (default 24) after it's taken in.
--   2. string_jobs.is_rush: a rush job is pinned to the top of the queue.
--   3. Both can be changed while the job is waiting to be strung, never after.
--      A promised time can't be cleared, can't be set in the past, and is at
--      most 90 days after drop-off.
--
-- Jobs taken in before this migration keep no promised time. Re-runnable.
-- =============================================================================

alter table settings add column if not exists stringing_turnaround_hours integer not null default 24;
alter table settings drop constraint if exists ck_settings_stringing_turnaround_hours;
alter table settings add constraint ck_settings_stringing_turnaround_hours
  check (stringing_turnaround_hours between 1 and 720);
comment on column settings.stringing_turnaround_hours is
  'How long after drop-off a string job is promised, unless staff set a time';

alter table string_jobs add column if not exists promised_at timestamptz;
alter table string_jobs add column if not exists is_rush boolean not null default false;
comment on column string_jobs.promised_at is 'When the customer was told the job would be ready';
comment on column string_jobs.is_rush is 'A rush job goes to the top of the queue';

create index if not exists ix_string_jobs_open_promised
  on string_jobs (is_rush desc, promised_at)
  where status = 'entered';

grant update (promised_at, is_rush) on string_jobs to authenticated;

-- -----------------------------------------------------------------------------
-- guard_string_job_promise — the default promise and its rules
-- -----------------------------------------------------------------------------
-- Runs after guard_new_string_job (trigger names sort that way), so a client's
-- new job already has its entered_at.
create or replace function guard_string_job_promise()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_client boolean := current_user in ('authenticated', 'anon');
begin
  if tg_op = 'INSERT' then
    if new.promised_at is null then
      new.promised_at := new.entered_at
        + make_interval(hours => coalesce((select stringing_turnaround_hours from settings where id), 24));
      return new;
    end if;
  else
    if new.promised_at is not distinct from old.promised_at and new.is_rush = old.is_rush then
      return new;
    end if;
    if v_client and old.status <> 'entered' then
      raise exception 'The racquet has been strung, so its promised time and rush can''t change';
    end if;
    if new.promised_at is null and old.promised_at is not null then
      raise exception 'A string job needs a promised time';
    end if;
    if new.promised_at is not distinct from old.promised_at then
      return new;
    end if;
  end if;

  if v_client then
    if new.promised_at < now() - interval '5 minutes' then
      raise exception 'The promised time (%) has already passed', to_char(new.promised_at, 'Mon DD HH24:MI');
    end if;
    if new.promised_at > new.entered_at + interval '90 days' then
      raise exception 'Promise the job within 90 days of drop-off';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_string_job_promise on string_jobs;
create trigger trg_string_job_promise
  before insert or update of promised_at, is_rush on string_jobs
  for each row execute function guard_string_job_promise();
