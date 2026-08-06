-- =============================================================================
-- 0009_stock_views.sql — derived stock + low-stock views (AceStock)
--
-- On-hand is always derived from the append-only inventory_txns ledger, never
-- stored. These views expose it conveniently, plus a low-stock flag using the
-- effective reorder point (variant's own, falling back to the product's).
-- =============================================================================

-- Per-variant on-hand + low-stock flag.
create or replace view variant_stock_detail as
select
  v.id                                              as variant_id,
  v.product_id                                      as product_id,
  coalesce(sum(t.qty), 0)::numeric                  as on_hand,
  coalesce(v.reorder_point, p.reorder_point)        as reorder_point,
  (
    coalesce(v.reorder_point, p.reorder_point) is not null
    and coalesce(sum(t.qty), 0) <= coalesce(v.reorder_point, p.reorder_point)
  )                                                 as is_low
from variants v
join products p on p.id = v.product_id
left join inventory_txns t on t.variant_id = v.id
group by v.id, v.product_id, v.reorder_point, p.reorder_point;

-- Per-product roll-up: total on-hand, variant count, any low-stock variant.
create or replace view product_stock as
select
  p.id                                              as product_id,
  coalesce(sum(vsd.on_hand), 0)::numeric            as on_hand,
  count(v.id)                                       as variant_count,
  coalesce(bool_or(vsd.is_low), false)              as has_low_stock
from products p
left join variants v on v.product_id = p.id
left join variant_stock_detail vsd on vsd.variant_id = v.id
group by p.id;

grant select on variant_stock_detail to authenticated;
grant select on product_stock to authenticated;
