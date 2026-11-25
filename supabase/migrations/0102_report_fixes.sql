-- =============================================================================
-- 0102_report_fixes.sql — stringing split and returned jobs (AceStock, Phase 4A review)
--
-- Fixes from the 4A code review:
--   1. A job's strings price (string_job_strings_price) includes the shop's
--      labour charge, so the stringing report gave almost everything to
--      strings. string_jobs.labor_price now keeps the labour charge in that
--      price, set whenever the strings price is (trigger below); jobs before
--      now get today's labour charge, never more than their strings price.
--   2. report_stringing_summary: strings = strings price less labour (never
--      more than the charge; a customer's own string is labour only); a string
--      change is all strings. strings_revenue and labor_revenue are now net of
--      refunds, each refund split in its line's own proportion. Otherwise as
--      0099.
--   3. report_sales_by: a refunded string change is money back, not another
--      returned job (only a first charge's return counts as a quantity).
--      Otherwise as 0095.
--
-- Re-runnable.
-- =============================================================================

-- 1. string_jobs.labor_price --------------------------------------------------
alter table string_jobs add column if not exists labor_price numeric(12, 2);
alter table string_jobs drop constraint if exists ck_string_jobs_labor_price;
alter table string_jobs add constraint ck_string_jobs_labor_price
  check (labor_price >= 0 and labor_price <> 'NaN');
comment on column string_jobs.labor_price is
  'The labour charge included in strings_price when it was set (0102); the strings are the rest';

create or replace function set_string_job_labor_price()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' or new.strings_price is distinct from old.strings_price then
    new.labor_price := case
      when new.strings_price is null then null
      else least(coalesce((select stringing_labor from settings where id), 0), new.strings_price)
    end;
  end if;
  return new;
end;
$$;

revoke all on function set_string_job_labor_price() from public, anon, authenticated;

-- Named to run after trg_guard_string_job_strings, which sets strings_price.
drop trigger if exists trg_string_job_labor_price on string_jobs;
create trigger trg_string_job_labor_price
  before insert or update on string_jobs
  for each row execute function set_string_job_labor_price();

update string_jobs j
   set labor_price = least(coalesce((select stringing_labor from settings where id), 0), j.strings_price)
 where j.labor_price is null and j.strings_price is not null;

-- 2. report_sales_by ------------------------------------------------------------
create or replace function report_sales_by(p_from timestamptz, p_to timestamptz, p_group text)
returns table (
  group_key      text,
  label          text,
  detail         text,
  tickets        integer,
  qty_sold       integer,
  sales          numeric,
  discounts      numeric,
  qty_returned   integer,
  returns        numeric,
  net_qty        integer,
  net_sales      numeric,
  costed_sales   numeric,
  cost           numeric,
  margin         numeric,
  margin_pct     numeric,
  uncosted_qty   integer,
  cost_estimated boolean
)
language plpgsql
stable
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform require_admin();
  perform require_report_range(p_from, p_to);
  if p_group is null or p_group not in ('category', 'brand', 'product', 'staff') then
    raise exception 'A sales report is by category, brand, product or staff, not %', coalesce(p_group, '(nothing)')
      using errcode = '22023';
  end if;

  return query
  with moves as (
    -- Sold in the period. Only a line's first charge counts as items sold; a
    -- later string change adds money, not another job.
    select s.id as sale_id, s.user_id, sl.product_id,
           case when sl.kind = 'charge' then sl.qty else 0 end as qty,
           sl.qty * sl.unit_price as amount,
           sl.qty * (coalesce(sl.price_before_discount, sl.unit_price) - sl.unit_price) as discount,
           sl.qty as cost_qty, sl.unit_cost, sl.unit_cost_estimated,
           false as is_return
      from sale_lines sl
      join sales s on s.id = sl.sale_id
     where s.sold_at >= p_from and s.sold_at < p_to
       and sl.gift_card_id is null
    union all
    -- Refunded in the period, against the line's original sale.
    select s.id, s.user_id, sl.product_id,
           case when rl.kind = 'return' and sl.kind = 'charge' then rl.qty else 0 end,
           rl.qty * rl.unit_price,
           0::numeric,
           -rl.qty, sl.unit_cost, sl.unit_cost_estimated,
           true
      from refund_lines rl
      join refunds r on r.id = rl.refund_id
      join sale_lines sl on sl.id = rl.sale_line_id
      join sales s on s.id = sl.sale_id
     where r.refunded_at >= p_from and r.refunded_at < p_to
       and sl.gift_card_id is null
  ),
  keyed as (
    select m.*,
           case
             when p_group = 'staff'   then coalesce(m.user_id::text, '')
             when m.product_id is null then 'stringing'
             when p_group = 'category' then p.category_id::text
             when p_group = 'brand'    then coalesce(nullif(trim(p.brand), ''), '')
             else p.id::text
           end as k,
           case
             when p_group = 'staff'   then coalesce(pr.email, '(not recorded)')
             when m.product_id is null then 'Stringing'
             when p_group = 'category' then c.name
             when p_group = 'brand'    then coalesce(nullif(trim(p.brand), ''), '(no brand)')
             else trim(coalesce(p.brand, '') || ' ' || p.name)
           end as lbl,
           case
             when p_group = 'product' and m.product_id is not null then c.name
           end as dtl
      from moves m
      left join products p   on p.id = m.product_id
      left join categories c on c.id = p.category_id
      left join profiles pr  on pr.id = m.user_id
  ),
  grouped as (
    select k, min(lbl) as lbl, min(dtl) as dtl,
           count(distinct sale_id) filter (where not is_return)::int                 as tickets,
           coalesce(sum(qty) filter (where not is_return), 0)::int                   as qty_sold,
           coalesce(sum(amount) filter (where not is_return), 0)                     as sales,
           coalesce(sum(discount), 0)                                                as discounts,
           coalesce(sum(qty) filter (where is_return), 0)::int                       as qty_returned,
           coalesce(sum(amount) filter (where is_return), 0)                         as returns,
           coalesce(sum(case when is_return then -amount else amount end)
                    filter (where unit_cost is not null), 0)                         as costed_sales,
           coalesce(sum(cost_qty * unit_cost), 0)                                    as cost,
           count(*) filter (where unit_cost is not null) > 0                         as has_cost,
           coalesce(sum(cost_qty) filter (where product_id is not null and unit_cost is null), 0)::int
                                                                                     as uncosted_qty,
           coalesce(bool_or(unit_cost_estimated), false)                             as cost_estimated
      from keyed
     group by k
  )
  select g.k, g.lbl, g.dtl, g.tickets, g.qty_sold, g.sales, g.discounts, g.qty_returned, g.returns,
         g.qty_sold - g.qty_returned,
         g.sales - g.returns,
         g.costed_sales,
         g.cost,
         case when g.has_cost then g.costed_sales - g.cost end,
         case when g.has_cost and g.costed_sales <> 0
              then round(100 * (g.costed_sales - g.cost) / g.costed_sales, 1) end,
         g.uncosted_qty,
         g.cost_estimated
    from grouped g
   order by g.sales - g.returns desc, g.lbl;
end;
$$;

revoke all on function report_sales_by(timestamptz, timestamptz, text) from public, anon;
grant execute on function report_sales_by(timestamptz, timestamptz, text) to authenticated;

-- 3. report_stringing_summary --------------------------------------------------
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
    -- Each stringing line sold in any period, with the part that was the
    -- shop's strings: a first charge's strings are the job's strings price
    -- less its labour (never more than the charge); a string change is all
    -- strings.
    select sl.id, s.sold_at, sl.qty * sl.unit_price as amount,
           case when sl.kind = 'charge'
                then least(greatest(coalesce(j.strings_price, 0) - coalesce(j.labor_price, 0), 0) * sl.qty,
                           sl.qty * sl.unit_price)
                else sl.qty * sl.unit_price
           end as strings_part
      from sale_lines sl
      join sales s on s.id = sl.sale_id
      join string_jobs j on j.id = sl.string_job_id
  ),
  charges as (
    select amount, strings_part from charge_lines
     where sold_at >= p_from and sold_at < p_to
  ),
  given_back as (
    -- Refunds split between strings and labour in the line's own proportion.
    select rl.qty * rl.unit_price as amount,
           case when c.amount = 0 then 0
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
