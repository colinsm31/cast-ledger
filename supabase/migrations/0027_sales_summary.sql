-- =============================================================================
-- 0027_sales_summary.sql — sales report totals for a period (AceStock)
--
-- Aggregates sales in [p_from, p_to) into the figures shown on the sales report
-- screen. Refunds and check tenders are 0 for now (returns / check payments are
-- not yet implemented) but are surfaced so the report is complete.
--
-- Re-runnable.
-- =============================================================================

create or replace function sales_summary(p_from timestamptz, p_to timestamptz)
returns table (
  gross         numeric,
  refunds       numeric,
  net           numeric,
  card          numeric,
  cash          numeric,
  check_amt     numeric,
  store_credit  numeric,
  gift_card     numeric,
  num_customers integer,
  num_tickets   integer,
  num_items     integer
)
language sql
security invoker
as $$
  with s as (
    select id, subtotal, customer_id
    from sales
    where sold_at >= p_from and sold_at < p_to
  ),
  pay as (
    select sp.method, sp.amount
    from sale_payments sp
    join s on s.id = sp.sale_id
  )
  select
    coalesce((select sum(subtotal) from s), 0)                                             as gross,
    0::numeric                                                                             as refunds,
    coalesce((select sum(subtotal) from s), 0)                                             as net,
    coalesce((select sum(amount) from pay where method = 'credit'), 0)                     as card,
    coalesce((select sum(amount) from pay where method = 'cash'), 0)                       as cash,
    0::numeric                                                                             as check_amt,
    coalesce((select sum(amount) from pay where method = 'store_credit'), 0)               as store_credit,
    coalesce((select sum(amount) from pay where method = 'gift_card'), 0)                  as gift_card,
    (select count(distinct customer_id) from s where customer_id is not null)::int         as num_customers,
    (select count(*) from s)::int                                                          as num_tickets,
    coalesce((select sum(sl.qty) from sale_lines sl join s on s.id = sl.sale_id
              where sl.product_id is not null), 0)::int                                    as num_items;
$$;
grant execute on function sales_summary(timestamptz, timestamptz) to authenticated;
