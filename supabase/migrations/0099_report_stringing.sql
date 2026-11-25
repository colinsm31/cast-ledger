-- =============================================================================
-- 0099_report_stringing.sql — stringing volume and revenue (AceStock, Phase 4A)
--
-- Adds, for a period [from, to):
--   1. report_stringing_summary(from, to) — one row:
--        * jobs entered (and how many were rush), completed, delivered and
--          cancelled in the period, and jobs waiting now;
--        * revenue: stringing charges on sales in the period (string changes
--          included), refunds of stringing made in the period, and net;
--        * strings_revenue: the part of each charge that was the shop's
--          strings (the job's strings price, never more than the charge);
--          labor_revenue is the rest.
--   2. report_stringing(from, to) — jobs completed in the period by stringer
--      (as recorded on the job, "(not recorded)" otherwise): how many, rush,
--      customer's own string, finished by the promised time or after, and the
--      average hours from entered to complete.
--
-- Admins only; run with the caller's rights. Re-runnable.
-- =============================================================================

-- 1. report_stringing_summary -------------------------------------------------
drop function if exists report_stringing_summary(timestamptz, timestamptz);
create or replace function report_stringing_summary(p_from timestamptz, p_to timestamptz)
returns table (
  jobs_entered    integer,
  rush_entered    integer,
  jobs_completed  integer,
  jobs_delivered  integer,
  jobs_cancelled  integer,
  jobs_waiting    integer,
  revenue         numeric,
  strings_revenue numeric,
  labor_revenue   numeric,
  refunds         numeric,
  net_revenue     numeric
)
language plpgsql
stable
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform require_admin();
  perform require_report_range(p_from, p_to);

  return query
  with charges as (
    select sl.qty * sl.unit_price as amount,
           case when sl.kind = 'charge'
                then least(coalesce(j.strings_price, 0) * sl.qty, sl.qty * sl.unit_price)
                else sl.qty * sl.unit_price  -- a string change is a strings difference
           end as strings_part
      from sale_lines sl
      join sales s on s.id = sl.sale_id
      join string_jobs j on j.id = sl.string_job_id
     where s.sold_at >= p_from and s.sold_at < p_to
  ),
  given_back as (
    select rl.qty * rl.unit_price as amount
      from refund_lines rl
      join refunds r on r.id = rl.refund_id
      join sale_lines sl on sl.id = rl.sale_line_id
     where sl.string_job_id is not null
       and r.refunded_at >= p_from and r.refunded_at < p_to
  ),
  totals as (
    select coalesce((select sum(amount) from charges), 0)       as rev,
           coalesce((select sum(strings_part) from charges), 0) as strings_rev,
           coalesce((select sum(amount) from given_back), 0)    as back
  )
  select
    (select count(*) from string_jobs j where j.entered_at >= p_from and j.entered_at < p_to)::int,
    (select count(*) from string_jobs j where j.entered_at >= p_from and j.entered_at < p_to and j.is_rush)::int,
    (select count(*) from string_jobs j where j.completed_at >= p_from and j.completed_at < p_to)::int,
    (select count(*) from string_jobs j where j.delivered_at >= p_from and j.delivered_at < p_to)::int,
    (select count(*) from string_jobs j where j.cancelled_at >= p_from and j.cancelled_at < p_to)::int,
    (select count(*) from string_jobs j where j.status = 'entered')::int,
    t.rev,
    t.strings_rev,
    t.rev - t.strings_rev,
    t.back,
    t.rev - t.back
  from totals t;
end;
$$;

revoke all on function report_stringing_summary(timestamptz, timestamptz) from public, anon;
grant execute on function report_stringing_summary(timestamptz, timestamptz) to authenticated;

-- 2. report_stringing ---------------------------------------------------------
drop function if exists report_stringing(timestamptz, timestamptz);
create or replace function report_stringing(p_from timestamptz, p_to timestamptz)
returns table (
  stringer          text,
  jobs_completed    integer,
  rush              integer,
  customer_supplied integer,
  on_time           integer,
  late              integer,
  avg_hours         numeric
)
language plpgsql
stable
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform require_admin();
  perform require_report_range(p_from, p_to);

  return query
  select coalesce(nullif(trim(j.strung_by), ''), '(not recorded)') as who,
         count(*)::int,
         count(*) filter (where j.is_rush)::int,
         count(*) filter (where j.main_customer_supplied or j.cross_customer_supplied)::int,
         count(*) filter (where j.promised_at is not null and j.completed_at <= j.promised_at)::int,
         count(*) filter (where j.promised_at is not null and j.completed_at > j.promised_at)::int,
         round((avg(extract(epoch from (j.completed_at - j.entered_at))) / 3600)::numeric, 1)
    from string_jobs j
   where j.completed_at >= p_from and j.completed_at < p_to
   group by 1
   order by 2 desc, 1;
end;
$$;

revoke all on function report_stringing(timestamptz, timestamptz) from public, anon;
grant execute on function report_stringing(timestamptz, timestamptz) to authenticated;
