-- =============================================================================
-- 0118_report_sort_tie_breakers.sql — report rows in one fixed order
-- (AceStock, 4B review 15)
--
-- The Reports page loads a long report 1,000 rows at a time. Four reports
-- sorted on columns that can tie (two products with the same name, two
-- customers with the same name and no code), so a row could move between
-- pages and be skipped or shown twice while sales came in. Each now ends its
-- sort on its unique key. (The price-changes and daily-summary reports already
-- sort uniquely; stringing sorts by stringer, which is unique.)
--
-- Only the last sort column changes in each function. Re-runnable.
-- =============================================================================

-- report_sales_by — as in 0102, with a last tie-breaker.
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
   order by g.sales - g.returns desc, g.lbl, g.k;
end;
$$;

revoke all on function report_sales_by(timestamptz, timestamptz, text) from public, anon;
grant execute on function report_sales_by(timestamptz, timestamptz, text) to authenticated;

-- report_inventory_value — as in 0097, with a last tie-breaker.
create or replace function report_inventory_value()
returns table (
  product_id         uuid,
  product            text,
  category           text,
  brand              text,
  is_serialized      boolean,
  on_hand            numeric,
  cost               numeric,
  sell_price         numeric,
  value_at_cost      numeric,
  retail_value       numeric,
  demo_frames        integer,
  demo_value_at_cost numeric
)
language plpgsql
stable
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform require_admin();

  return query
  with demo as (
    select u.product_id as pid, count(*)::int as frames
      from product_units u
     where u.status in ('demo', 'assigned')
     group by u.product_id
  )
  select p.id,
         trim(coalesce(p.brand, '') || ' ' || p.name),
         c.name,
         nullif(trim(p.brand), ''),
         p.is_serialized,
         ps.on_hand,
         p.cost,
         p.sell_price,
         greatest(ps.on_hand, 0) * p.cost,
         greatest(ps.on_hand, 0) * p.sell_price,
         coalesce(d.frames, 0),
         case when d.frames is not null then d.frames * p.cost end
    from products p
    join product_stock ps on ps.product_id = p.id
    left join categories c on c.id = p.category_id
    left join demo d on d.pid = p.id
   where ps.on_hand <> 0 or d.frames is not null
   order by c.sort_order nulls last, c.name, nullif(trim(p.brand), '') nulls last, p.name, p.id;
end;
$$;

revoke all on function report_inventory_value() from public, anon;
grant execute on function report_inventory_value() to authenticated;

-- report_balances — as in 0098, with a last tie-breaker.
create or replace function report_balances(p_as_of timestamptz)
returns table (
  kind          text,
  holder_id     uuid,
  code          text,
  customer      text,
  balance       numeric,
  last_activity timestamptz,
  is_active     boolean
)
language plpgsql
stable
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform require_admin();
  if p_as_of is null then
    raise exception 'Choose the moment to report balances at'
      using errcode = '22023';
  end if;

  return query
  with cards as (
    select t.gift_card_id as id, sum(t.amount) as bal, max(t.created_at) as last_at
      from gift_card_txns t
     where t.created_at < p_as_of
     group by t.gift_card_id
    having sum(t.amount) <> 0
  ),
  credit as (
    select t.customer_id as id, sum(t.amount) as bal, max(t.created_at) as last_at
      from store_credit_txns t
     where t.created_at < p_as_of
     group by t.customer_id
    having sum(t.amount) <> 0
  )
  select 'gift_card'::text, gc.id, gc.code,
         case when cu.id is not null then cu.last_name || ', ' || cu.first_name end,
         c.bal, c.last_at, gc.is_active
    from cards c
    join gift_cards gc on gc.id = c.id
    left join customers cu on cu.id = gc.customer_id
  union all
  select 'store_credit'::text, cu.id, null::text,
         cu.last_name || ', ' || cu.first_name,
         c.bal, c.last_at, cu.is_active
    from credit c
    join customers cu on cu.id = c.id
  order by 1, 4 nulls last, 3, 2;
end;
$$;

revoke all on function report_balances(timestamptz) from public, anon;
grant execute on function report_balances(timestamptz) to authenticated;

-- report_demos — as in 0100, with a last tie-breaker.
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
   order by b.lent desc, b.open desc, 2, 1;
end;
$$;

revoke all on function report_demos(timestamptz, timestamptz) from public, anon;
grant execute on function report_demos(timestamptz, timestamptz) to authenticated;
