-- =============================================================================
-- 0020_string_job_cancel.sql — cancel a string job (AceStock)
--
-- Adds a 'cancelled' state so an entered job can be voided (e.g. the customer
-- changes their mind before it's strung). Cancelling releases the job's stock
-- reservation automatically, since committed stock is derived from jobs still in
-- the 'entered' state. Only an entered job may be cancelled — once it's strung
-- (complete) the string has been consumed.
--
-- Re-runnable.
-- =============================================================================

alter table string_jobs drop constraint if exists string_jobs_status_check;
alter table string_jobs
  add constraint string_jobs_status_check
  check (status in ('entered', 'complete', 'delivered', 'cancelled'));

create or replace function cancel_string_job(p_job_id uuid)
returns text
language plpgsql
security invoker
as $$
declare
  v_current text;
begin
  select status into v_current from string_jobs where id = p_job_id;
  if v_current is null then
    raise exception 'Unknown string job %', p_job_id;
  end if;
  if v_current <> 'entered' then
    raise exception 'Only an entered job can be cancelled (this one is "%")', v_current;
  end if;
  update string_jobs set status = 'cancelled' where id = p_job_id;
  return 'cancelled';
end;
$$;
grant execute on function cancel_string_job(uuid) to authenticated;
