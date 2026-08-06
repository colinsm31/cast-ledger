-- =============================================================================
-- 0017_products_only.sql — collapse the variant layer (AceStock)
--
-- Simplifies the model: each PRODUCT is now the unique, sellable, stock-tracked
-- item under a category. The separate `variants` table is removed. Stock ledger,
-- sale lines, and string-job catalog links all point at products directly, and a
-- product's attributes JSONB holds every field (including what used to be
-- variant dimensions like gauge/color).
--
-- CLEAN CUTOVER: stock + sales history is wiped and rebuilt against products
-- (there is no real sales/stock data yet). Re-runnable.
-- =============================================================================

-- 1. Drop variant-dependent RPCs (recreated below, keyed on product_id).
drop function if exists receive_stock(uuid, numeric, numeric, text, text);
drop function if exists adjust_stock(uuid, numeric, text);
drop function if exists record_sale(jsonb, text);

-- 2. Drop variant-dependent views.
drop view if exists product_stock;
drop view if exists variant_stock_detail;
drop view if exists variant_stock;

-- 3. Wipe stock + sales history (clean cutover; rebuilt against products).
truncate inventory_txns, sale_lines, sales cascade;

-- 4. Repoint the stock ledger at products.
drop index if exists idx_inventory_txns_variant;
alter table inventory_txns drop column if exists variant_id;
alter table inventory_txns
  add column if not exists product_id uuid not null references products (id);
create index if not exists idx_inventory_txns_product on inventory_txns (product_id);

-- 5. Repoint sale lines at products.
drop index if exists idx_sale_lines_variant;
alter table sale_lines drop column if exists variant_id;
alter table sale_lines
  add column if not exists product_id uuid not null references products (id);
create index if not exists idx_sale_lines_product on sale_lines (product_id);

-- 6. Repoint string-job catalog links at products.
alter table string_jobs drop column if exists main_variant_id;
alter table string_jobs drop column if exists cross_variant_id;
alter table string_jobs
  add column if not exists main_product_id  uuid references products (id),
  add column if not exists cross_product_id uuid references products (id);

-- 7. Drop the variants table itself.
drop table if exists variants cascade;

-- 8. Attributes are all plain product fields now — the variant-dimension flag is
--    obsolete.
alter table attribute_defs drop column if exists is_variant_dimension;

-- 9. A UPC now identifies a product (was per-variant). Enforce uniqueness here.
create unique index if not exists uq_products_barcode
  on products (barcode)
  where barcode is not null;

-- 10. Per-product stock view: on-hand from the ledger + a low-stock flag against
--     the product's own reorder point.
create or replace view product_stock as
select
  p.id                                      as product_id,
  coalesce(sum(t.qty), 0)::numeric          as on_hand,
  p.reorder_point                           as reorder_point,
  (
    p.reorder_point is not null
    and coalesce(sum(t.qty), 0) <= p.reorder_point
  )                                         as is_low
from products p
left join inventory_txns t on t.product_id = p.id
group by p.id, p.reorder_point;

grant select on product_stock to authenticated;

-- =============================================================================
-- 11. RPCs (product-keyed)
-- =============================================================================

-- receive_stock — post a positive receive txn for a product. Returns txn id.
create or replace function receive_stock(
  p_product_id uuid,
  p_qty        numeric,
  p_unit_cost  numeric,
  p_location   text,
  p_note       text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  if p_qty is null or p_qty <= 0 then
    raise exception 'Receive quantity must be positive';
  end if;
  if not exists (select 1 from products where id = p_product_id) then
    raise exception 'Unknown product_id %', p_product_id;
  end if;
  insert into inventory_txns (id, txn_type, product_id, qty, unit_cost, location, note)
  values (v_id, 'receive', p_product_id, p_qty, p_unit_cost, nullif(trim(p_location),''), nullif(trim(p_note),''));
  return v_id;
end;
$$;
grant execute on function receive_stock(uuid, numeric, numeric, text, text) to authenticated;

-- adjust_stock — post a signed adjustment (shrinkage, count correction).
create or replace function adjust_stock(
  p_product_id uuid,
  p_qty        numeric,
  p_note       text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  if p_qty is null or p_qty = 0 then
    raise exception 'Adjustment quantity must be non-zero';
  end if;
  if not exists (select 1 from products where id = p_product_id) then
    raise exception 'Unknown product_id %', p_product_id;
  end if;
  insert into inventory_txns (id, txn_type, product_id, qty, note)
  values (v_id, 'adjust', p_product_id, p_qty, nullif(trim(p_note),''));
  return v_id;
end;
$$;
grant execute on function adjust_stock(uuid, numeric, text) to authenticated;

-- record_sale — atomic POS write: a sale header + its lines + one negative
-- 'sell' inventory_txn per line. Input lines: [{product_id, qty, unit_price}].
create or replace function record_sale(
  p_lines jsonb,
  p_note  text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_sale_id   uuid := gen_random_uuid();
  v_line      jsonb;
  v_product   uuid;
  v_qty       integer;
  v_price     numeric;
  v_subtotal  numeric := 0;
begin
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'A sale needs at least one line';
  end if;

  insert into sales (id, subtotal, note) values (v_sale_id, 0, nullif(trim(p_note),''));

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_product := (v_line->>'product_id')::uuid;
    v_qty     := (v_line->>'qty')::integer;
    v_price   := (v_line->>'unit_price')::numeric;

    if v_product is null or not exists (select 1 from products where id = v_product) then
      raise exception 'Unknown product_id % in sale line', v_product;
    end if;
    if v_qty is null or v_qty <= 0 then
      raise exception 'Sale line quantity must be positive';
    end if;
    if v_price is null or v_price < 0 then
      raise exception 'Sale line price must be >= 0';
    end if;

    insert into sale_lines (sale_id, product_id, qty, unit_price)
    values (v_sale_id, v_product, v_qty, v_price);

    insert into inventory_txns (txn_type, product_id, qty, sale_id)
    values ('sell', v_product, -v_qty, v_sale_id);

    v_subtotal := v_subtotal + (v_qty * v_price);
  end loop;

  update sales set subtotal = v_subtotal where id = v_sale_id;
  return v_sale_id;
end;
$$;
grant execute on function record_sale(jsonb, text) to authenticated;
