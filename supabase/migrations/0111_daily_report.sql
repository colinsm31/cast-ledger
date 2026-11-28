-- =============================================================================
-- 0111_daily_report.sql — the daily (X / Z) report (AceStock, Phase 4B)
--
-- Adds:
--   1. daily_money_amounts(from, to, time zone) — each day's money, signed as
--      in the QuickBooks summary (0101): what was taken by each payment type
--      (+) and given back (−); items, stringing and gift cards sold (−) and
--      returned (+); tax charged (−) and refunded (+). Each row says whether
--      it came from a sale or a refund. Moved out of report_daily_summary,
--      which now reads it (same output; test 65 unchanged).
--   2. report_day(day) — one business day (the shop's time zone, 0108) as a
--      JSON report for printing: sales and refunds (counts, items, gift cards,
--      tax, totals), exchange credit, totals by payment type (taken, given
--      back, net), sales by category, and each drawer opened that day (float,
--      cash in and out, paid-ins and -outs, expected, counted, over/short).
--      Any staff member can print it (they close the day); it reads with the
--      caller's rights.
--
-- Re-runnable.
-- =============================================================================

-- 1. daily_money_amounts ----------------------------------------------------------
drop function if exists daily_money_amounts(timestamptz, timestamptz, text);
create or replace function daily_money_amounts(p_from timestamptz, p_to timestamptz, p_time_zone text)
returns table (
  d      date,
  source text,
  what   text,
  amt    numeric
)
language sql
stable
set search_path = public, pg_temp
as $$
  with s as (
    select x.id, (x.sold_at at time zone p_time_zone)::date as d, x.tax
      from sales x where x.sold_at >= p_from and x.sold_at < p_to
  ),
  r as (
    select x.id, (x.refunded_at at time zone p_time_zone)::date as d, x.tax
      from refunds x where x.refunded_at >= p_from and x.refunded_at < p_to
  )
  -- Positive amounts are debits, negative credits.
  select s.d, 'sale', sp.method, sp.amount
    from sale_payments sp join s on s.id = sp.sale_id
   where sp.method <> 'exchange'
  union all
  select r.d, 'refund', rp.method, -rp.amount
    from refund_payments rp join r on r.id = rp.refund_id
   where rp.method <> 'exchange'
  union all
  select s.d, 'sale',
         case when sl.gift_card_id is not null then 'gift_card_sold'
              when sl.product_id is null then 'stringing'
              else 'sales:' || coalesce(c.name, '(no category)') end,
         -(sl.qty * sl.unit_price)
    from sale_lines sl join s on s.id = sl.sale_id
    left join products p on p.id = sl.product_id
    left join categories c on c.id = p.category_id
  union all
  select r.d, 'refund',
         case when sl.gift_card_id is not null then 'gift_card_sold'
              when sl.product_id is null then 'stringing'
              else 'sales:' || coalesce(c.name, '(no category)') end,
         rl.qty * rl.unit_price
    from refund_lines rl join r on r.id = rl.refund_id
    join sale_lines sl on sl.id = rl.sale_line_id
    left join products p on p.id = sl.product_id
    left join categories c on c.id = p.category_id
  union all
  select s.d, 'sale', 'tax', -s.tax from s
  union all
  select r.d, 'refund', 'tax', r.tax from r;
$$;
revoke all on function daily_money_amounts(timestamptz, timestamptz, text) from public, anon;
grant execute on function daily_money_amounts(timestamptz, timestamptz, text) to authenticated;

-- report_daily_summary — same as 0101, reading daily_money_amounts --------------
drop function if exists report_daily_summary(timestamptz, timestamptz, text);
create or replace function report_daily_summary(p_from timestamptz, p_to timestamptz, p_time_zone text)
returns table (
  day     date,
  line_no integer,
  account text,
  debit   numeric,
  credit  numeric,
  memo    text
)
language plpgsql
stable
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v settings%rowtype;
begin
  perform require_admin();
  perform require_report_range(p_from, p_to);
  if p_time_zone is null or not exists (select 1 from pg_timezone_names where name = p_time_zone) then
    raise exception 'Unknown time zone: %', coalesce(p_time_zone, '(none)')
      using errcode = '22023';
  end if;
  select * into v from settings where id;

  return query
  with amounts as (
    select a.d, a.what, a.amt from daily_money_amounts(p_from, p_to, p_time_zone) a
  ),
  named as (
    select a.d,
           case a.what
             when 'cash'           then v.qb_cash_account
             when 'credit'         then v.qb_card_account
             when 'check'          then v.qb_check_account
             when 'gift_card'      then v.qb_gift_card_account
             when 'gift_card_sold' then v.qb_gift_card_account
             when 'store_credit'   then v.qb_store_credit_account
             when 'tax'            then v.qb_sales_tax_account
             when 'stringing'      then v.qb_stringing_account
             else v.qb_sales_account
           end as acct,
           case a.what
             when 'cash'           then 'Cash'
             when 'credit'         then 'Card'
             when 'check'          then 'Checks'
             when 'gift_card'      then 'Paid by gift card'
             when 'gift_card_sold' then 'Gift cards sold'
             when 'store_credit'   then 'Paid by store credit'
             when 'tax'            then 'Sales tax'
             when 'stringing'      then 'Stringing'
             else 'Sales: ' || substr(a.what, 7)
           end as note,
           case a.what
             when 'cash' then 1 when 'credit' then 2 when 'check' then 3
             when 'gift_card' then 4 when 'store_credit' then 5
             when 'stringing' then 7 when 'gift_card_sold' then 8 when 'tax' then 9
             else 6
           end as ord,
           a.amt
      from amounts a
  ),
  summed as (
    select n.d, n.acct, n.note, min(n.ord) as ord, sum(n.amt) as total
      from named n
     group by n.d, n.acct, n.note
    having sum(n.amt) <> 0
  )
  select x.d,
         (row_number() over (partition by x.d order by x.ord, x.note))::int,
         x.acct,
         case when x.total > 0 then x.total end,
         case when x.total < 0 then -x.total end,
         x.note
    from summed x
   order by x.d, 2;
end;
$$;

revoke all on function report_daily_summary(timestamptz, timestamptz, text) from public, anon;
grant execute on function report_daily_summary(timestamptz, timestamptz, text) to authenticated;

-- 2. report_day ------------------------------------------------------------------
drop function if exists report_day(date);
create or replace function report_day(p_day date)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_zone   text;
  v_from   timestamptz;
  v_to     timestamptz;
  v_result jsonb;
begin
  perform require_staff();
  if p_day is null then
    raise exception 'Choose a day' using errcode = '22023';
  end if;
  select time_zone into v_zone from settings where id;
  if v_zone is null then
    raise exception 'An admin needs to set the shop''s time zone in Settings first' using errcode = '22023';
  end if;
  v_from := p_day::timestamp at time zone v_zone;
  v_to := (p_day + 1)::timestamp at time zone v_zone;

  with a as (
    select * from daily_money_amounts(v_from, v_to, v_zone)
  ),
  is_item as (
    select a.*, (a.what = 'stringing' or a.what like 'sales:%') as item from a
  ),
  methods(method, label, ord) as (
    values ('cash', 'Cash', 1), ('credit', 'Card', 2), ('check', 'Check', 3),
           ('gift_card', 'Gift card', 4), ('store_credit', 'Store credit', 5)
  ),
  payments as (
    select m.method, m.label, m.ord,
           coalesce(sum(a.amt) filter (where a.source = 'sale'), 0) as taken,
           coalesce(-sum(a.amt) filter (where a.source = 'refund'), 0) as given_back
      from methods m left join a on a.what = m.method
     group by m.method, m.label, m.ord
  ),
  categories as (
    select case when what = 'stringing' then 'Stringing' else substr(what, 7) end as name,
           -coalesce(sum(amt) filter (where source = 'sale'), 0) as sold,
           coalesce(sum(amt) filter (where source = 'refund'), 0) as returned
      from is_item where item
     group by 1
  ),
  sessions as (
    select dr.name as drawer_name, ds.opened_at, ds.closed_at, ds.counted_cash,
           -- An open drawer's expected cash is worked out now; a closed one's as saved.
           coalesce(ds.expected_cash, x.expected_cash) as expected,
           x.float_amount, x.cash_sales, x.cash_refunds, x.paid_in, x.paid_out
      from drawer_sessions ds
      join drawers dr on dr.id = ds.drawer_id
      cross join lateral drawer_cash_summary(ds.id) x
     where ds.business_day = p_day
  )
  select jsonb_build_object(
    'day', p_day,
    'time_zone', v_zone,
    'sales', jsonb_build_object(
      'count', (select count(*) from sales where sold_at >= v_from and sold_at < v_to),
      'items', coalesce((select -sum(amt) from is_item where source = 'sale' and item), 0),
      'gift_cards', coalesce((select -sum(amt) from a where source = 'sale' and what = 'gift_card_sold'), 0),
      'tax', coalesce((select -sum(amt) from a where source = 'sale' and what = 'tax'), 0)),
    'refunds', jsonb_build_object(
      'count', (select count(*) from refunds where refunded_at >= v_from and refunded_at < v_to),
      'items', coalesce((select sum(amt) from is_item where source = 'refund' and item), 0),
      'gift_cards', coalesce((select sum(amt) from a where source = 'refund' and what = 'gift_card_sold'), 0),
      'tax', coalesce((select sum(amt) from a where source = 'refund' and what = 'tax'), 0)),
    'exchanges', jsonb_build_object(
      'count', (select count(*) from exchanges where created_at >= v_from and created_at < v_to),
      'credit', coalesce((select sum(credit) from exchanges where created_at >= v_from and created_at < v_to), 0)),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object('method', method, 'label', label, 'taken', taken,
                                          'given_back', given_back, 'net', taken - given_back) order by ord)
        from payments where taken <> 0 or given_back <> 0), '[]'::jsonb),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('name', name, 'sold', sold, 'returned', returned, 'net', sold - returned)
                       order by name)
        from categories), '[]'::jsonb),
    'drawers', coalesce((
      select jsonb_agg(jsonb_build_object(
               'drawer', drawer_name, 'opened_at', opened_at, 'closed_at', closed_at,
               'float', float_amount, 'cash_sales', cash_sales, 'cash_refunds', cash_refunds,
               'paid_in', paid_in, 'paid_out', paid_out, 'expected', expected,
               'counted', counted_cash, 'over_short', counted_cash - expected)
             order by drawer_name, opened_at)
        from sessions), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function report_day(date) from public, anon;
grant execute on function report_day(date) to authenticated;
