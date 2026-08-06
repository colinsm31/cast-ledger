-- =============================================================================
-- 0015_string_jobs.sql — string jobs with mains/crosses + lifecycle (AceStock)
--
-- Replaces the simpler racket_stringings (0014) with a string_jobs record that
-- captures the mains and crosses separately (brand, string, color, gauge,
-- tension each) and a lifecycle: entered → complete → delivered. A job becomes
-- part of a racket's re-stringing history once delivered.
--
-- Re-runnable: drops the old table/fn and recreates string_jobs.
-- =============================================================================

drop function if exists record_stringing(uuid, uuid, text, numeric, numeric, numeric, text, boolean, text);
drop function if exists advance_string_job(uuid, text);
drop table if exists racket_stringings cascade;
drop table if exists string_jobs cascade;

create table string_jobs (
  id                 uuid primary key default gen_random_uuid(),
  customer_racket_id uuid not null references customer_rackets (id) on delete cascade,
  status             text not null default 'entered'
                       check (status in ('entered', 'complete', 'delivered')),

  -- Mains
  main_variant_id    uuid references variants (id),   -- optional catalog string
  main_brand         text,
  main_string        text,
  main_color         text,
  main_gauge         text,
  main_tension       numeric(5, 1) check (main_tension > 0),

  -- Crosses (may differ from mains for a hybrid)
  cross_variant_id   uuid references variants (id),
  cross_brand        text,
  cross_string       text,
  cross_color        text,
  cross_gauge        text,
  cross_tension      numeric(5, 1) check (cross_tension > 0),

  price              numeric(12, 2) check (price >= 0),
  strung_by          text,
  notes              text,

  entered_at         timestamptz not null default now(),
  completed_at       timestamptz,
  delivered_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index idx_string_jobs_racket on string_jobs (customer_racket_id);
create index idx_string_jobs_status on string_jobs (status);

create trigger trg_string_jobs_updated_at
  before update on string_jobs
  for each row execute function set_updated_at();

-- RLS + grants
alter table string_jobs enable row level security;
create policy string_jobs_authenticated_all
  on string_jobs for all to authenticated using (true) with check (true);
grant select, insert, update, delete on string_jobs to authenticated;

-- -----------------------------------------------------------------------------
-- advance_string_job — move a job exactly one step forward
--   (entered → complete → delivered) and stamp the corresponding timestamp.
--   Returns the new status.
-- -----------------------------------------------------------------------------
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
begin
  select status into v_current from string_jobs where id = p_job_id;
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

  return p_target_status;
end;
$$;

grant execute on function advance_string_job(uuid, text) to authenticated;
