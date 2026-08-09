-- =============================================================================
-- 0025_gift_card_ownership.sql — gift card ownership follows the balance
--
-- A gift card is only "owned" by a customer while it holds value:
--   • redeeming a card to $0 clears its customer (it becomes anonymous)
--   • loading value onto an EMPTY card (re)assigns it to that sale's customer
--     (null when sold to an unidentified customer)
-- A card with an existing balance keeps its owner when topped up.
--
-- Only record_sale changes. Re-runnable.
-- =============================================================================

create or replace function record_sale(
  p_lines       jsonb,
  p_customer_id uuid,
  p_payments    jsonb,
  p_note        text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_sale_id   uuid := gen_random_uuid();
  v_line      jsonb;
  v_pay       jsonb;
  v_product   uuid;
  v_job       uuid;
  v_gc        uuid;
  v_qty       integer;
  v_price     numeric;
  v_subtotal  numeric := 0;
  v_paid      numeric := 0;
  v_method    text;
  v_amount    numeric;
  v_bal       numeric;
  v_prev      numeric;
  v_count     integer;
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

  -- Lines
  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_product := nullif(v_line->>'product_id', '')::uuid;
    v_job     := nullif(v_line->>'string_job_id', '')::uuid;
    v_gc      := nullif(v_line->>'gift_card_id', '')::uuid;
    v_qty     := (v_line->>'qty')::integer;
    v_price   := (v_line->>'unit_price')::numeric;

    if v_qty is null or v_qty <= 0 then
      raise exception 'Sale line quantity must be positive';
    end if;
    if v_price is null or v_price < 0 then
      raise exception 'Sale line price must be >= 0';
    end if;
    if (case when v_product is null then 0 else 1 end)
     + (case when v_job is null then 0 else 1 end)
     + (case when v_gc is null then 0 else 1 end) <> 1 then
      raise exception 'A sale line must reference exactly one of product, string job, or gift card';
    end if;

    if v_product is not null then
      if not exists (select 1 from products where id = v_product) then
        raise exception 'Unknown product_id % in sale line', v_product;
      end if;
      insert into sale_lines (sale_id, product_id, qty, unit_price)
      values (v_sale_id, v_product, v_qty, v_price);
      insert into inventory_txns (txn_type, product_id, qty, sale_id)
      values ('sell', v_product, -v_qty, v_sale_id);
    elsif v_job is not null then
      if not exists (select 1 from string_jobs where id = v_job) then
        raise exception 'Unknown string_job_id % in sale line', v_job;
      end if;
      insert into sale_lines (sale_id, string_job_id, qty, unit_price)
      values (v_sale_id, v_job, v_qty, v_price);
      update string_jobs set paid_sale_id = v_sale_id where id = v_job;
    else
      if not exists (select 1 from gift_cards where id = v_gc) then
        raise exception 'Unknown gift_card_id % in sale line', v_gc;
      end if;
      -- Balance before this load decides whether ownership is (re)assigned.
      select coalesce(sum(amount), 0) into v_prev from gift_card_txns where gift_card_id = v_gc;
      insert into sale_lines (sale_id, gift_card_id, qty, unit_price)
      values (v_sale_id, v_gc, v_qty, v_price);
      insert into gift_card_txns (gift_card_id, amount, reason, sale_id)
      values (v_gc, v_qty * v_price, 'load', v_sale_id);
      -- Loading an empty card assigns it to this sale's customer (null = anon).
      if v_prev <= 0 then
        update gift_cards set customer_id = p_customer_id where id = v_gc;
      end if;
    end if;

    v_subtotal := v_subtotal + (v_qty * v_price);
  end loop;

  -- Payments (split tender)
  if p_payments is not null then
    for v_pay in select * from jsonb_array_elements(p_payments)
    loop
      v_method := v_pay->>'method';
      v_amount := (v_pay->>'amount')::numeric;
      v_gc     := nullif(v_pay->>'gift_card_id', '')::uuid;

      if v_amount is null or v_amount <= 0 then
        raise exception 'Payment amount must be positive';
      end if;
      if v_method not in ('cash', 'credit', 'gift_card', 'store_credit') then
        raise exception 'Invalid payment method "%"', v_method;
      end if;

      if v_method = 'gift_card' then
        if v_gc is null then raise exception 'Gift card payment needs a gift_card_id'; end if;
        select coalesce(sum(amount), 0) into v_bal from gift_card_txns where gift_card_id = v_gc;
        if v_bal < v_amount then
          raise exception 'Gift card balance % is less than %', v_bal, v_amount;
        end if;
        insert into gift_card_txns (gift_card_id, amount, reason, sale_id)
        values (v_gc, -v_amount, 'redeem', v_sale_id);
        insert into sale_payments (sale_id, method, amount, gift_card_id)
        values (v_sale_id, 'gift_card', v_amount, v_gc);
        -- Fully-redeemed card is no longer owned by anyone.
        select coalesce(sum(amount), 0) into v_bal from gift_card_txns where gift_card_id = v_gc;
        if v_bal <= 0 then
          update gift_cards set customer_id = null where id = v_gc;
        end if;
      elsif v_method = 'store_credit' then
        if p_customer_id is null then raise exception 'Store credit needs a customer on the sale'; end if;
        select coalesce(sum(amount), 0) into v_bal from store_credit_txns where customer_id = p_customer_id;
        if v_bal < v_amount then
          raise exception 'Store credit balance % is less than %', v_bal, v_amount;
        end if;
        insert into store_credit_txns (customer_id, amount, reason, sale_id)
        values (p_customer_id, -v_amount, 'redeem', v_sale_id);
        insert into sale_payments (sale_id, method, amount)
        values (v_sale_id, 'store_credit', v_amount);
      else
        insert into sale_payments (sale_id, method, amount)
        values (v_sale_id, v_method, v_amount);
      end if;

      v_paid := v_paid + v_amount;
    end loop;
  end if;

  if abs(v_paid - v_subtotal) > 0.005 then
    raise exception 'Payments (%) must equal the sale total (%)', v_paid, v_subtotal;
  end if;

  select count(*) into v_count from sale_payments where sale_id = v_sale_id;
  update sales
     set subtotal = v_subtotal,
         payment_method = case
           when v_count = 0 then null
           when v_count = 1 then (select method from sale_payments where sale_id = v_sale_id limit 1)
           else 'split'
         end
   where id = v_sale_id;

  return v_sale_id;
end;
$$;
grant execute on function record_sale(jsonb, uuid, jsonb, text) to authenticated;
