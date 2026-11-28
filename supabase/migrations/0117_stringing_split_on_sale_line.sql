-- =============================================================================
-- 0117_stringing_split_on_sale_line.sql — a stringing charge's strings and
-- labour, saved when it's rung (AceStock, 4B review 5)
--
-- The stringing report worked out a charge's strings part from the job's
-- strings price and labour as they are now. A string change overwrites both,
-- so after one, the first charge's split was wrong (e.g. $18 labour + $20
-- string, then a $30 string: it read $40 strings / $8 labour, not $30 / $18).
--
--   1. sale_lines.strings_amount / labor_amount: set when a stringing line is
--      written. A first charge's strings are the job's strings price less its
--      labour then (never more than the charge); a string-change charge is all
--      strings.
--   2. Older lines are filled in: a first charge from the job's strings price
--      before its string changes, marked split_estimated.
--   3. report_stringing_summary reads the saved split; a string change's
--      give-back counts as strings, not split by proportion.
--
-- report_stringing_summary as in 0102 except where marked. Re-runnable.
-- =============================================================================

-- 1. The split on the line ----------------------------------------------------------
alter table sale_lines add column if not exists strings_amount  numeric(12, 2);
alter table sale_lines add column if not exists labor_amount    numeric(12, 2);
alter table sale_lines add column if not exists split_estimated boolean not null default false;
comment on column sale_lines.strings_amount is 'A stringing line''s strings part when it was rung (0117); null for other lines';
comment on column sale_lines.labor_amount is 'A stringing line''s labour part when it was rung (0117)';
comment on column sale_lines.split_estimated is 'The split was filled in for a line rung before 0117';

create or replace function set_sale_line_strings_split()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_job string_jobs%rowtype;
begin
  if new.string_job_id is null then
    return new;
  end if;
  if new.kind = 'string_change' then
    new.strings_amount := new.qty * new.unit_price;
  else
    select * into v_job from string_jobs where id = new.string_job_id;
    new.strings_amount := least(greatest(coalesce(v_job.strings_price, 0) - coalesce(v_job.labor_price, 0), 0) * new.qty,
                                new.qty * new.unit_price);
  end if;
  new.labor_amount := new.qty * new.unit_price - new.strings_amount;
  return new;
end;
$$;
revoke all on function set_sale_line_strings_split() from public, anon, authenticated;

drop trigger if exists trg_sale_lines_strings_split on sale_lines;
create trigger trg_sale_lines_strings_split before insert on sale_lines
  for each row execute function set_sale_line_strings_split();

-- 2. Older lines --------------------------------------------------------------------
-- Fills in the split on stringing lines rung before 0117 (run once below).
create or replace function fill_sale_line_strings_split()
returns void
language plpgsql
set search_path = public, pg_temp
as $$
begin
  update sale_lines
     set strings_amount = qty * unit_price, labor_amount = 0
   where string_job_id is not null and kind = 'string_change' and strings_amount is null;

  with changes as (
    -- What string changes added to each job's strings price (charges less give-backs).
    select sl.string_job_id as job_id, sum(sl.qty * sl.unit_price) as amount
      from sale_lines sl where sl.kind = 'string_change' group by sl.string_job_id
    union all
    select sl.string_job_id, -sum(rl.qty * rl.unit_price)
      from refund_lines rl join sale_lines sl on sl.id = rl.sale_line_id
     where rl.kind = 'string_change' group by sl.string_job_id
  ),
  first_price as (
    select j.id, coalesce(j.strings_price, 0) - coalesce((select sum(c.amount) from changes c where c.job_id = j.id), 0)
             as strings_price,
           coalesce(j.labor_price, 0) as labor_price
      from string_jobs j
  )
  update sale_lines sl
     set strings_amount = least(greatest(f.strings_price - f.labor_price, 0) * sl.qty, sl.qty * sl.unit_price),
         labor_amount = sl.qty * sl.unit_price
                        - least(greatest(f.strings_price - f.labor_price, 0) * sl.qty, sl.qty * sl.unit_price),
         split_estimated = true
    from first_price f
   where f.id = sl.string_job_id and sl.kind = 'charge' and sl.strings_amount is null;
end;
$$;
revoke all on function fill_sale_line_strings_split() from public, anon, authenticated;

select fill_sale_line_strings_split();

-- 3. report_stringing_summary -------------------------------------------------------
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
  with charge_lines as (
    -- Each stringing line sold in any period, with the strings part saved on
    -- the line when it was rung (0117).
    select sl.id, s.sold_at, sl.qty * sl.unit_price as amount, coalesce(sl.strings_amount, 0) as strings_part
      from sale_lines sl
      join sales s on s.id = sl.sale_id
     where sl.string_job_id is not null
  ),
  charges as (
    select amount, strings_part from charge_lines
     where sold_at >= p_from and sold_at < p_to
  ),
  given_back as (
    -- A string change's give-back is all strings; other refunds split in the
    -- line's own proportion.
    select rl.qty * rl.unit_price as amount,
           case when rl.kind = 'string_change' then rl.qty * rl.unit_price
                when c.amount = 0 then 0
                else round(rl.qty * rl.unit_price * c.strings_part / c.amount, 2) end as strings_part
      from refund_lines rl
      join refunds r on r.id = rl.refund_id
      join charge_lines c on c.id = rl.sale_line_id
     where r.refunded_at >= p_from and r.refunded_at < p_to
  ),
  totals as (
    select coalesce((select sum(amount) from charges), 0)                                        as rev,
           coalesce((select sum(strings_part) from charges), 0)
             - coalesce((select sum(strings_part) from given_back), 0)                           as strings_rev,
           coalesce((select sum(amount) from given_back), 0)                                     as back
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
    t.rev - t.back - t.strings_rev,
    t.back,
    t.rev - t.back
  from totals t;
end;
$$;

revoke all on function report_stringing_summary(timestamptz, timestamptz) from public, anon;
grant execute on function report_stringing_summary(timestamptz, timestamptz) to authenticated;
