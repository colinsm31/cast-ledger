-- =============================================================================
-- 0021_record_sale_products.sql — product-keyed POS sale (AceStock)
--
-- The 3-arg record_sale(p_lines, p_customer_id, p_note) from 0012 still
-- referenced the old `variants` table (removed in 0017), so it was broken.
-- Recreate it product-keyed: each line is {product_id, qty, unit_price}. A sale
-- may carry an optional customer (null = walk-up / unidentified). Also drops the
-- leftover 2-arg product record_sale so there's a single canonical function.
--
-- Re-runnable.
-- =============================================================================

drop function if exists record_sale(jsonb, text);

create or replace function record_sale(
  p_lines       jsonb,
  p_customer_id uuid,
  p_note        text
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
  if p_customer_id is not null
     and not exists (select 1 from customers where id = p_customer_id) then
    raise exception 'Unknown customer_id %', p_customer_id;
  end if;

  insert into sales (id, customer_id, subtotal, note)
  values (v_sale_id, p_customer_id, 0, nullif(trim(p_note), ''));

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
grant execute on function record_sale(jsonb, uuid, text) to authenticated;
