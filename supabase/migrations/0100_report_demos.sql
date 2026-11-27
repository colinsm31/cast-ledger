-- =============================================================================
-- 0100_report_demos.sql — demo program activity (AceStock, Phase 4A)
--
-- Adds report_demos(from, to): the demo program by racquet model:
--   * loans: demos lent in [from, to);
--   * led_to_sale: of those, how many the borrower then bought a frame of the
--     same racquet (demo_loans.sale_id, set within 30 days; 0072), and the
--     conversion % (led_to_sale / loans);
--   * returned: demos checked back in during the period, retired: of those,
--     how many were retired on the way back; avg_days_out: their average
--     time out;
--   * out_now / overdue_now: demos lent out at this moment, and of those, how
--     many are past their due-back time.
-- Models with nothing in any column are left out.
--
-- Admins only; runs with the caller's rights. Re-runnable.
-- =============================================================================

drop function if exists report_demos(timestamptz, timestamptz);
create or replace function report_demos(p_from timestamptz, p_to timestamptz)
returns table (
  product_id     uuid,
  racquet        text,
  loans          integer,
  led_to_sale    integer,
  conversion_pct numeric,
  returned       integer,
  retired        integer,
  avg_days_out   numeric,
  out_now        integer,
  overdue_now    integer
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
  with loans as (
    select u.product_id as pid, l.*
      from demo_loans l
      join product_units u on u.id = l.product_unit_id
  ),
  by_model as (
    select pid,
           count(*) filter (where out_at >= p_from and out_at < p_to)::int                         as lent,
           count(*) filter (where out_at >= p_from and out_at < p_to and sale_id is not null)::int as sold,
           count(*) filter (where back_at >= p_from and back_at < p_to)::int                       as back,
           count(*) filter (where back_at >= p_from and back_at < p_to and back_status = 'retired')::int
                                                                                                   as gone,
           avg(extract(epoch from (back_at - out_at)) / 86400)
             filter (where back_at >= p_from and back_at < p_to)                                   as days,
           count(*) filter (where back_at is null)::int                                            as open,
           count(*) filter (where back_at is null and due_back_at < now())::int                    as late
      from loans
     group by pid
  )
  select b.pid,
         trim(coalesce(p.brand, '') || ' ' || p.name),
         b.lent,
         b.sold,
         case when b.lent > 0 then round(100.0 * b.sold / b.lent, 1) end,
         b.back,
         b.gone,
         round(b.days::numeric, 1),
         b.open,
         b.late
    from by_model b
    join products p on p.id = b.pid
   where b.lent + b.back + b.open > 0
   order by b.lent desc, b.open desc, 2;
end;
$$;

revoke all on function report_demos(timestamptz, timestamptz) from public, anon;
grant execute on function report_demos(timestamptz, timestamptz) to authenticated;
