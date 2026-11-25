-- =============================================================================
-- 0097_report_inventory_value.sql — inventory value at cost (AceStock, Phase 4A)
--
-- Adds report_inventory_value(): what's in stock now, product by product:
--   * on_hand: as product_stock counts it (frames in stock for racquets, the
--     stock history's sum for everything else). Shown as recorded, so an
--     oversold item shows below zero, but it's valued at zero, not less.
--   * value_at_cost: on hand x the product's cost; null when no cost is
--     recorded (the screen counts those rather than valuing them at $0).
--   * retail_value: on hand x the selling price.
--   * demo_frames / demo_value_at_cost: frames in the demo fleet (in the demo
--     rack or lent out), kept apart from stock for sale.
-- Products with nothing on hand and no demo frames are left out.
--
-- Admins only; runs with the caller's rights. Re-runnable.
-- =============================================================================

drop function if exists report_inventory_value();
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
   order by c.sort_order nulls last, c.name, nullif(trim(p.brand), '') nulls last, p.name;
end;
$$;

revoke all on function report_inventory_value() from public, anon;
grant execute on function report_inventory_value() to authenticated;
