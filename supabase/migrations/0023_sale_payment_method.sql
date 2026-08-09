-- =============================================================================
-- 0023_sale_payment_method.sql — payment method on sales (AceStock)
--
-- The cashier picks how the customer paid: credit, cash, gift card, or store
-- credit. Stored on the sale; record_sale gains a p_payment_method argument.
--
-- Re-runnable.
-- =============================================================================

alter table sales add column if not exists payment_method text;
alter table sales drop constraint if exists sales_payment_method_check;
alter table sales
  add constraint sales_payment_method_check
  check (payment_method is null or payment_method in ('credit', 'cash', 'gift_card', 'store_credit'));

drop function if exists record_sale(jsonb, uuid, text);

create or replace function record_sale(
  p_lines          jsonb,
  p_customer_id    uuid,
  p_payment_method text,
  p_note           text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_sale_id   uuid := gen_random_uuid();
  v_line      jsonb;
  v_product   uuid;
  v_job       uuid;
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

  insert into sales (id, customer_id, payment_method, subtotal, note)
  values (v_sale_id, p_customer_id, p_payment_method, 0, nullif(trim(p_note), ''));

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_product := nullif(v_line->>'product_id', '')::uuid;
    v_job     := nullif(v_line->>'string_job_id', '')::uuid;
    v_qty     := (v_line->>'qty')::integer;
    v_price   := (v_line->>'unit_price')::numeric;

    if v_qty is null or v_qty <= 0 then
      raise exception 'Sale line quantity must be positive';
    end if;
    if v_price is null or v_price < 0 then
      raise exception 'Sale line price must be >= 0';
    end if;
    if (v_product is not null) = (v_job is not null) then
      raise exception 'A sale line must reference exactly one of product or string job';
    end if;

    if v_product is not null then
      if not exists (select 1 from products where id = v_product) then
        raise exception 'Unknown product_id % in sale line', v_product;
      end if;
      insert into sale_lines (sale_id, product_id, qty, unit_price)
      values (v_sale_id, v_product, v_qty, v_price);
      insert into inventory_txns (txn_type, product_id, qty, sale_id)
      values ('sell', v_product, -v_qty, v_sale_id);
    else
      if not exists (select 1 from string_jobs where id = v_job) then
        raise exception 'Unknown string_job_id % in sale line', v_job;
      end if;
      insert into sale_lines (sale_id, string_job_id, qty, unit_price)
      values (v_sale_id, v_job, v_qty, v_price);
      update string_jobs set paid_sale_id = v_sale_id where id = v_job;
    end if;

    v_subtotal := v_subtotal + (v_qty * v_price);
  end loop;

  update sales set subtotal = v_subtotal where id = v_sale_id;
  return v_sale_id;
end;
$$;
grant execute on function record_sale(jsonb, uuid, text, text) to authenticated;
