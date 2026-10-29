-- =============================================================================
-- 0048_sales_summary.sql — gift cards counted once, items net of returns
--                          (AceStock, foundation code review #24)
--
-- Before:
--   • Gross receipts included gift card loads, so a $50 card sold and later
--     spent on $50 of goods added $100 of sales.
--   • "Items sold" counted everything rung up, ignoring returns.
--
-- Now:
--   1. gross is products and stringing only. A gift card counts as a sale when
--      it's spent (the goods it buys are in gross), not when it's sold.
--   2. New gift_cards_sold: the value loaded onto gift cards in the period,
--      reported on its own (money taken in that's owed back as goods).
--   3. net stays "money actually taken in": gross + tax − refunds + gift cards
--      sold, so it still equals the tender totals. Gift card loads can't be
--      returned (0030), so refunds never include them.
--   4. num_items is product quantities sold in the period, minus product
--      quantities returned in the period.
--
-- The return type gains a column, so the function is dropped and recreated;
-- it still runs with the caller's permissions (security invoker), so the
-- staff-only row rules decide what it sees, and only signed-in users can call
-- it. Re-runnable.
-- =============================================================================

drop function if exists sales_summary(timestamptz, timestamptz);

create function sales_summary(p_from timestamptz, p_to timestamptz)
returns table (
  gross           numeric,
  tax             numeric,
  refunds         numeric,
  net             numeric,
  card            numeric,
  cash            numeric,
  check_amt       numeric,
  store_credit    numeric,
  gift_card       numeric,
  num_customers   integer,
  num_tickets     integer,
  num_items       integer,
  gift_cards_sold numeric
)
language sql
stable
set search_path = public, pg_temp
as $$
  with s as (
    select id, tax, customer_id from sales where sold_at >= p_from and sold_at < p_to
  ),
  lines as (
    select sl.qty, sl.unit_price, sl.product_id, sl.gift_card_id
    from sale_lines sl join s on s.id = sl.sale_id
  ),
  pay as (select sp.method, sp.amount from sale_payments sp join s on s.id = sp.sale_id),
  r as (select id, subtotal, tax from refunds where refunded_at >= p_from and refunded_at < p_to),
  rpay as (select rp.method, rp.amount from refund_payments rp join r on r.id = rp.refund_id),
  returned_items as (
    select rl.qty
    from refund_lines rl
    join r on r.id = rl.refund_id
    join sale_lines sl on sl.id = rl.sale_line_id
    where sl.product_id is not null
  ),
  totals as (
    select
      coalesce((select sum(qty * unit_price) from lines where gift_card_id is null), 0) as gross,
      coalesce((select sum(qty * unit_price) from lines where gift_card_id is not null), 0) as gift_cards_sold,
      coalesce((select sum(tax) from s), 0)                                              as tax,
      coalesce((select sum(subtotal + tax) from r), 0)                                   as refunds
  )
  select
    t.gross,
    t.tax,
    t.refunds,
    t.gross + t.tax - t.refunds + t.gift_cards_sold                                             as net,
    coalesce((select sum(amount) from pay where method = 'credit'), 0)
      - coalesce((select sum(amount) from rpay where method = 'credit'), 0)                     as card,
    coalesce((select sum(amount) from pay where method = 'cash'), 0)
      - coalesce((select sum(amount) from rpay where method = 'cash'), 0)                       as cash,
    0::numeric                                                                                  as check_amt,
    coalesce((select sum(amount) from pay where method = 'store_credit'), 0)
      - coalesce((select sum(amount) from rpay where method = 'store_credit'), 0)               as store_credit,
    coalesce((select sum(amount) from pay where method = 'gift_card'), 0)
      - coalesce((select sum(amount) from rpay where method = 'gift_card'), 0)                  as gift_card,
    (select count(distinct customer_id) from s where customer_id is not null)::int              as num_customers,
    (select count(*) from s)::int                                                               as num_tickets,
    (coalesce((select sum(qty) from lines where product_id is not null), 0)
      - coalesce((select sum(qty) from returned_items), 0))::int                                as num_items,
    t.gift_cards_sold
  from totals t;
$$;

revoke all on function sales_summary(timestamptz, timestamptz) from public, anon;
grant execute on function sales_summary(timestamptz, timestamptz) to authenticated;
