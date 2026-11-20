-- =============================================================================
-- 0070_racquet_returns.sql — return a sold racquet frame (AceStock, Phase 3B)
--
-- Before:
--   • record_refund refused any serialized line ("Returning individual
--     (serialized) items is not supported yet"), so a sold racquet couldn't
--     be returned.
--
-- Now (record_refund, otherwise the same as 0054):
--   1. A frame's sale line can be returned, one frame (qty 1) per line. The
--      refund itself is as for any product: the price paid, the sale's tax
--      rate, and the payment-type rules.
--   2. Each returned frame line may say what happens to the frame:
--        unit_status  'in_stock' (default) or 'retired' (damaged);
--        unit_reason  why, required when retired (at most 200 characters).
--      The frame must still be sold on this sale. It leaves the customer
--      (sale and customer cleared), its history records the return with the
--      refund, and no stock-ledger row is written (frames are counted).
--   3. The racquet made from the frame (0069) is taken off the customer's
--      racquets. A frame whose racquet has a string job open can't be
--      returned until that job is delivered or cancelled.
--
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- record_refund — same as 0054, plus returned frames
-- -----------------------------------------------------------------------------
create or replace function record_refund(
  p_sale_id              uuid,
  p_lines                jsonb,
  p_payments             jsonb,
  p_reason               text,
  p_note                 text,
  p_method_change_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_refund_id  uuid := gen_random_uuid();
  v_customer   uuid;
  v_rate       numeric := 0;
  v_sale_tax   numeric := 0;
  v_line       jsonb;
  v_pay        jsonb;
  v_sl_id      uuid;
  v_qty        integer;
  v_sl         record;
  v_returned   integer;
  v_sub        numeric := 0;
  v_tax        numeric := 0;
  v_total      numeric := 0;
  v_paid       numeric := 0;
  v_method     text;
  v_amount     numeric;
  v_gc         uuid;
  v_changed    text[];
  v_check_no   text;
  v_unit_to     text;
  v_unit_reason text;
  v_unit        product_units%rowtype;
begin
  perform require_cents_each(p_payments, 'amount', 'Refund amount');
  -- Locking the sale serializes refunds of the same sale, so remaining
  -- quantities, tax and per-method amounts below can't be raced.
  select customer_id, coalesce(tax_rate, 0), coalesce(tax, 0)
    into v_customer, v_rate, v_sale_tax
    from sales where id = p_sale_id
    for update;
  if not found then raise exception 'Unknown sale %', p_sale_id; end if;
  if p_lines is null or jsonb_array_length(p_lines) = 0 then raise exception 'A refund needs at least one line'; end if;

  insert into refunds (id, sale_id, reason, note)
  values (v_refund_id, p_sale_id, nullif(trim(p_reason), ''), nullif(trim(p_note), ''));

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_sl_id := (v_line->>'sale_line_id')::uuid;
    v_qty   := (v_line->>'qty')::integer;
    if v_qty is null or v_qty <= 0 then raise exception 'Return quantity must be positive'; end if;

    select * into v_sl from sale_lines where id = v_sl_id and sale_id = p_sale_id;
    if not found then raise exception 'Line % is not part of sale %', v_sl_id, p_sale_id; end if;
    if v_sl.product_id is null then raise exception 'Only product lines can be returned'; end if;
    if v_sl.product_unit_id is not null and v_qty <> 1 then
      raise exception 'A racquet frame is returned one at a time (qty 1)';
    end if;

    select coalesce(sum(rl.qty), 0) into v_returned from refund_lines rl where rl.sale_line_id = v_sl_id and rl.kind = 'return';
    if v_qty > v_sl.qty - v_returned then
      raise exception 'Cannot return % of line (only % remaining)', v_qty, v_sl.qty - v_returned;
    end if;

    insert into refund_lines (refund_id, sale_line_id, qty, unit_price)
    values (v_refund_id, v_sl_id, v_qty, v_sl.unit_price);

    if v_sl.product_unit_id is null then
      -- Returned stock goes back on hand.
      insert into inventory_txns (txn_type, product_id, qty, sale_id)
      values ('return', v_sl.product_id, v_qty, p_sale_id);
    else
      -- A returned frame goes back in stock, or is retired if it's damaged.
      v_unit_to     := coalesce(nullif(v_line->>'unit_status', ''), 'in_stock');
      v_unit_reason := nullif(btrim(coalesce(v_line->>'unit_reason', '')), '');
      if v_unit_to not in ('in_stock', 'retired') then
        raise exception 'A returned frame goes back in stock or is retired (not "%")', v_unit_to;
      end if;
      if v_unit_to = 'retired' and v_unit_reason is null then
        raise exception 'Say why the returned frame is retired';
      end if;
      if char_length(coalesce(v_unit_reason, '')) > 200 then
        raise exception 'Keep the reason to 200 characters';
      end if;

      select * into v_unit from product_units where id = v_sl.product_unit_id for update;
      if v_unit.status <> 'sold' or v_unit.sale_id is distinct from p_sale_id then
        raise exception 'This frame isn''t sold on this sale any more (it''s %)', replace(v_unit.status, '_', ' ');
      end if;
      if exists (select 1 from string_jobs j join customer_rackets r on r.id = j.customer_racket_id
                  where r.product_unit_id = v_unit.id and r.is_active and j.status in ('entered', 'complete')) then
        raise exception 'This racquet has a string job open: deliver or cancel it before returning the frame';
      end if;

      perform set_config('acestock.unit_status_reason', coalesce(v_unit_reason, 'Returned'), true);
      perform set_config('acestock.unit_refund_id', v_refund_id::text, true);
      update product_units
         set status = v_unit_to, sale_id = null, customer_id = null, updated_at = now()
       where id = v_unit.id;
      perform set_config('acestock.unit_status_reason', '', true);
      perform set_config('acestock.unit_refund_id', '', true);

      -- It's no longer the customer's racquet.
      update customer_rackets set is_active = false where product_unit_id = v_unit.id and is_active;
    end if;

    v_sub := v_sub + v_qty * v_sl.unit_price;
  end loop;

  -- Tax on everything taxable refunded so far (rounded once), minus tax
  -- already refunded, never beyond what the sale charged. Products are taxed.
  v_tax   := sale_refund_tax(p_sale_id, v_sub, v_refund_id);
  v_total := v_sub + v_tax;
  update refunds set subtotal = v_sub, tax = v_tax where id = v_refund_id;

  if p_payments is not null then
    for v_pay in select * from jsonb_array_elements(p_payments)
    loop
      v_method := v_pay->>'method';
      v_amount := (v_pay->>'amount')::numeric;
      v_gc     := nullif(v_pay->>'gift_card_id', '')::uuid;
      if v_amount is null or v_amount <= 0 then raise exception 'Refund amount must be positive'; end if;
      if v_method not in ('cash', 'credit', 'gift_card', 'store_credit', 'check') then raise exception 'Invalid refund method "%"', v_method; end if;
      v_check_no := null;

      if v_method = 'gift_card' then
        if v_gc is null then raise exception 'Gift card refund needs a gift_card_id'; end if;
        insert into gift_card_txns (gift_card_id, amount, reason, sale_id) values (v_gc, v_amount, 'refund', p_sale_id);
      elsif v_method = 'check' then
        -- A refund check: allowed while the shop takes checks, or when the sale
        -- itself was paid by check (even after checks were turned off).
        if not coalesce((select accept_checks from settings where id = true), false)
           and not exists (select 1 from sale_payments where sale_id = p_sale_id and method = 'check') then
          raise exception 'This shop doesn''t take checks: turn them on in Settings first';
        end if;
        v_check_no := require_check_number(v_pay->>'check_number');
      elsif v_method = 'store_credit' then
        if v_customer is null then raise exception 'Store credit refund needs a customer on the sale'; end if;
        insert into store_credit_txns (customer_id, amount, reason, sale_id) values (v_customer, v_amount, 'refund', p_sale_id);
      end if;

      insert into refund_payments (refund_id, method, amount, gift_card_id, check_number)
      values (v_refund_id, v_method, v_amount, v_gc, v_check_no);
      v_paid := v_paid + v_amount;
    end loop;
  end if;

  if abs(v_paid - v_total) > 0.005 then
    raise exception 'Refund payments (%) must equal the refund total (%)', v_paid, v_total;
  end if;

  -- A payment type this refund sends more to than the sale took that way (net
  -- of earlier refunds) is a payment-type change and needs a reason.
  v_changed := refund_method_overages(p_sale_id, v_refund_id);

  if cardinality(v_changed) > 0 then
    if coalesce(trim(p_method_change_reason), '') = '' then
      raise exception 'Refunding more to % than the sale took that way is a payment-type change; give a reason',
        array_to_string(v_changed, ', ');
    end if;
    update refunds set method_change_reason = trim(p_method_change_reason) where id = v_refund_id;
  end if;

  return v_refund_id;
end;
$$;

revoke all on function record_refund(uuid, jsonb, jsonb, text, text, text) from public, anon;
grant execute on function record_refund(uuid, jsonb, jsonb, text, text, text) to authenticated;
