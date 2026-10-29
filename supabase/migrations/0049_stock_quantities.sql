-- =============================================================================
-- 0049_stock_quantities.sql — stock quantities in whole or half units
--                              (AceStock, foundation code review #29)
--
-- Before:
--   • Receive and Adjust took any quantity, so typos like 1.37 or 0.0001 were
--     stored and the on-hand count stopped being a count.
--
-- Now:
--   1. A received or adjusted quantity is a whole number or a half (2, 2.5).
--      Halves are allowed because the stock imported from the old system
--      already counts string in half sets; existing quantities are untouched.
--   2. receive_stock and adjust_stock are the same as their latest versions
--      (0046 and 0045) plus that check at the start.
--
-- Re-runnable.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- 1. Internal helper: a quantity in whole or half units.
-- ----------------------------------------------------------------------------
create or replace function require_half_units(p_qty numeric, p_label text)
returns void
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  if p_qty is not null and p_qty * 2 <> trunc(p_qty * 2) then
    raise exception '% % must be a whole number or a half, like 2 or 2.5', p_label, trim_scale(p_qty);
  end if;
end;
$$;

revoke all on function require_half_units(numeric, text) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. The two functions that take a stock quantity.
-- ----------------------------------------------------------------------------
create or replace function receive_stock(
  p_product_id uuid,
  p_qty        numeric,
  p_unit_cost  numeric,
  p_location   text,
  p_note       text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id         uuid := gen_random_uuid();
  v_serialized boolean;
  v_name       text;
begin
  perform require_cents(p_unit_cost, 'Unit cost');
  perform require_half_units(p_qty, 'Quantity');
  if p_qty is null or p_qty <= 0 then
    raise exception 'Receive quantity must be positive';
  end if;
  select is_serialized, trim(coalesce(brand || ' ', '') || name) into v_serialized, v_name
    from products where id = p_product_id;
  if not found then
    raise exception 'Unknown product_id %', p_product_id;
  end if;
  if v_serialized then
    raise exception '% is tracked by unit; receive each one with its own barcode', v_name;
  end if;
  insert into inventory_txns (id, txn_type, product_id, qty, unit_cost, location, note)
  values (v_id, 'receive', p_product_id, p_qty, p_unit_cost, nullif(trim(p_location),''), nullif(trim(p_note),''));
  return v_id;
end;
$$;

create or replace function adjust_stock(p_product_id uuid, p_qty numeric, p_note text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id         uuid := gen_random_uuid();
  v_serialized boolean;
  v_name       text;
  v_on_hand    numeric;
begin
  perform require_half_units(p_qty, 'Quantity');
  if p_qty is null or p_qty = 0 then
    raise exception 'Adjustment quantity must be non-zero';
  end if;
  -- Lock the product, so a sale of the same item waits (and vice versa).
  select is_serialized, trim(coalesce(brand || ' ', '') || name) into v_serialized, v_name
    from products where id = p_product_id
    for update;
  if not found then
    raise exception 'Unknown product_id %', p_product_id;
  end if;
  if v_serialized then
    raise exception '% is tracked by unit; its stock is the units in stock, not an adjustable count', v_name;
  end if;

  if p_qty < 0 and coalesce((select block_oversell from settings where id), false) then
    select coalesce(sum(qty), 0) into v_on_hand from inventory_txns where product_id = p_product_id;
    if v_on_hand + p_qty < 0 then
      raise exception 'Only % of % on hand; this would take it to %',
        trim_scale(v_on_hand), v_name, trim_scale(v_on_hand + p_qty);
    end if;
  end if;

  insert into inventory_txns (id, txn_type, product_id, qty, note)
  values (v_id, 'adjust', p_product_id, p_qty, nullif(trim(p_note),''));
  return v_id;
end;
$$;

revoke all on function receive_stock(uuid, numeric, numeric, text, text) from public, anon;
revoke all on function adjust_stock(uuid, numeric, text) from public, anon;
grant execute on function receive_stock(uuid, numeric, numeric, text, text) to authenticated;
grant execute on function adjust_stock(uuid, numeric, text) to authenticated;
