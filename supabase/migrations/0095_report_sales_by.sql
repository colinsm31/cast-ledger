-- =============================================================================
-- 0095_report_sales_by.sql — sales, best-sellers and margin reports (AceStock, Phase 4A)
--
-- Adds:
--   1. require_admin() — refuses a signed-in account that isn't an admin, the
--      way require_staff() refuses one without staff access. Reports show
--      costs and margins, so only admins can run them.
--   2. require_report_range(from, to) — a report's period must have a start
--      before its end.
--   3. report_sales_by(from, to, group) — what sold in [from, to), grouped by
--      'category', 'brand', 'product' or 'staff':
--        * sales: what customers paid before tax, after discounts, for items
--          and stringing. Gift card loads aren't sales (they count when the
--          card is spent), so they're left out, as in sales_summary.
--        * returns: refunds made in the period, at the price refunded, counted
--          against the line's original category, brand, product and the staff
--          member who rang the sale.
--        * cost and margin: from each line's recorded cost (0094). Lines with
--          no cost are counted in uncosted_qty and left out of margin;
--          cost_estimated says some cost came from the 0094 backfill.
--      Stringing charges have no product: they're one "Stringing" row (no cost).
--
-- All three run with the caller's rights (row-level security applies).
-- Re-runnable.
-- =============================================================================

-- 1. require_admin ------------------------------------------------------------
create or replace function require_admin()
returns void
language plpgsql
stable
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is not null and not is_admin() then
    raise exception 'Only an admin can see reports'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function require_admin() from public, anon;
grant execute on function require_admin() to authenticated;

-- 2. require_report_range -----------------------------------------------------
create or replace function require_report_range(p_from timestamptz, p_to timestamptz)
returns void
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'A report needs a start before its end'
      using errcode = '22023';
  end if;
end;
$$;

revoke all on function require_report_range(timestamptz, timestamptz) from public, anon;
grant execute on function require_report_range(timestamptz, timestamptz) to authenticated;

-- 3. report_sales_by ----------------------------------------------------------
drop function if exists report_sales_by(timestamptz, timestamptz, text);
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
           case when rl.kind = 'return' then rl.qty else 0 end,
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
