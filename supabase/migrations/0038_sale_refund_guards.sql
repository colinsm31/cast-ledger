-- =============================================================================
-- 0038_sale_refund_guards.sql — money-path correctness (AceStock, Phase 1B)
--
-- 1. Concurrency. record_sale, record_refund and adjust_gift_card used to read
--    a balance (gift card, store credit, stock, returnable quantity) and then
--    act on it, so two registers working at the same moment could both pass
--    the check. Each now locks the rows it depends on first (`for update`, in
--    a fixed order: products → product_units → string_jobs → gift_cards →
--    customers, ids ascending) so the second register waits for the first and
--    then sees its result. record_refund locks the sale, which serializes all
--    refunds of that sale.
--
-- 2. String jobs can't be charged twice. record_sale rejects a job that is
--    already paid, cancelled, or on the same ticket twice; a trigger keeps a
--    paid job's price and paying sale from being changed afterwards.
--
-- 3. Refund payment types. Each payment type can give back up to what the sale
--    took that way (net of earlier refunds). Sending more to a type than that —
--    e.g. refunding a gift-card purchase as cash — is a payment-type change: any
--    staff member may do it, but must give a reason, which is stored on the
--    refund (refunds.method_change_reason) alongside who made it (user_id).
--
-- 4. Refund tax. Each refund used to round its own tax, so returning items in
--    separate refunds could give back a cent more tax than the sale charged
--    (2 × $5.05 at 8.25%: charged $0.83, refunded 0.42 + 0.42). Tax is now
--    computed on the cumulative refunded subtotal and never exceeds the tax the
--    sale charged.
--
-- record_refund gains an optional p_method_change_reason argument (default
-- null), so the old 5-argument version is dropped. Re-runnable.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- 1. Where a payment-type change is explained.
-- ----------------------------------------------------------------------------
alter table refunds add column if not exists method_change_reason text;

-- ----------------------------------------------------------------------------
-- 2. A paid string job keeps its price and its paying sale.
-- ----------------------------------------------------------------------------
create or replace function guard_paid_string_job()
returns trigger
language plpgsql
as $$
begin
  if old.paid_sale_id is not null then
    if new.paid_sale_id is distinct from old.paid_sale_id then
      raise exception 'String job % is already paid by sale %', old.id, old.paid_sale_id;
    end if;
    if new.price is distinct from old.price then
      raise exception 'The price of a paid string job can''t be changed';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_paid_string_job on string_jobs;
create trigger trg_guard_paid_string_job
  before update of paid_sale_id, price on string_jobs
  for each row execute function guard_paid_string_job();

-- ----------------------------------------------------------------------------
-- 3. record_sale — same behavior as 0032, plus row locks and the string-job
--    payment guard.
-- ----------------------------------------------------------------------------
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
  v_sale_id     uuid := gen_random_uuid();
  v_line        jsonb;
  v_pay         jsonb;
  v_product     uuid;
  v_unit        uuid;
  v_serialized  boolean;
  v_job         uuid;
  v_job_status  text;
  v_job_paid    uuid;
  v_gc          uuid;
  v_qty         integer;
  v_price       numeric;
  v_line_total  numeric;
  v_subtotal    numeric := 0;
  v_taxable     numeric := 0;
  v_paid        numeric := 0;
  v_method      text;
  v_amount      numeric;
  v_bal         numeric;
  v_prev        numeric;
  v_onhand      numeric;
  v_count       integer;
  v_rate        numeric := 0;
  v_tax_string  boolean := false;
  v_block       boolean := false;
  v_tax         numeric := 0;
  v_unit_status text;
  v_unit_prod   uuid;
begin
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'A sale needs at least one line';
  end if;
  if p_customer_id is not null
     and not exists (select 1 from customers where id = p_customer_id) then
    raise exception 'Unknown customer_id %', p_customer_id;
  end if;

  select tax_rate, tax_stringing, block_oversell
    into v_rate, v_tax_string, v_block
    from settings where id = true;
  v_rate := coalesce(v_rate, 0);

  -- Lock everything whose balance or state this sale checks, in a fixed order,
  -- so a concurrent sale waits here and then sees this sale's effects.
  if v_block then
    perform 1 from products
     where id in (select nullif(l->>'product_id', '')::uuid from jsonb_array_elements(p_lines) l)
     order by id for update;
  end if;
  perform 1 from product_units
   where id in (select nullif(l->>'product_unit_id', '')::uuid from jsonb_array_elements(p_lines) l)
   order by id for update;
  perform 1 from string_jobs
   where id in (select nullif(l->>'string_job_id', '')::uuid from jsonb_array_elements(p_lines) l)
   order by id for update;
  perform 1 from gift_cards
   where id in (
     select nullif(l->>'gift_card_id', '')::uuid from jsonb_array_elements(p_lines) l
     union
     select nullif(p->>'gift_card_id', '')::uuid from jsonb_array_elements(coalesce(p_payments, '[]'::jsonb)) p)
   order by id for update;
  if p_customer_id is not null and exists (
       select 1 from jsonb_array_elements(coalesce(p_payments, '[]'::jsonb)) p
       where p->>'method' = 'store_credit') then
    perform 1 from customers where id = p_customer_id for update;
  end if;

  insert into sales (id, customer_id, subtotal, note)
  values (v_sale_id, p_customer_id, 0, nullif(trim(p_note), ''));

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_product := nullif(v_line->>'product_id', '')::uuid;
    v_unit    := nullif(v_line->>'product_unit_id', '')::uuid;
    v_job     := nullif(v_line->>'string_job_id', '')::uuid;
    v_gc      := nullif(v_line->>'gift_card_id', '')::uuid;
    v_qty     := (v_line->>'qty')::integer;
    v_price   := (v_line->>'unit_price')::numeric;

    if v_qty is null or v_qty <= 0 then raise exception 'Sale line quantity must be positive'; end if;
    if v_price is null or v_price < 0 then raise exception 'Sale line price must be >= 0'; end if;
    if (case when v_product is null then 0 else 1 end)
     + (case when v_job is null then 0 else 1 end)
     + (case when v_gc is null then 0 else 1 end) <> 1 then
      raise exception 'A sale line must reference exactly one of product, string job, or gift card';
    end if;

    v_line_total := v_qty * v_price;

    if v_product is not null then
      select is_serialized into v_serialized from products where id = v_product;
      if v_serialized is null then
        raise exception 'Unknown product_id % in sale line', v_product;
      end if;

      if v_serialized then
        -- Serialized: sell one specific physical unit; no stock ledger txn.
        if v_unit is null then
          raise exception 'Product % is serialized; a product_unit_id is required', v_product;
        end if;
        if v_qty <> 1 then
          raise exception 'Serialized items sell one unit per line (qty must be 1)';
        end if;
        select status, product_id into v_unit_status, v_unit_prod
          from product_units where id = v_unit;
        if v_unit_status is null then raise exception 'Unknown product_unit_id %', v_unit; end if;
        if v_unit_prod <> v_product then raise exception 'Unit % does not belong to product %', v_unit, v_product; end if;
        if v_unit_status <> 'in_stock' then raise exception 'Unit % is not in stock (status %)', v_unit, v_unit_status; end if;

        insert into sale_lines (sale_id, product_id, product_unit_id, qty, unit_price)
        values (v_sale_id, v_product, v_unit, v_qty, v_price);
        update product_units
           set status = 'sold', sale_id = v_sale_id, customer_id = p_customer_id, updated_at = now()
         where id = v_unit;
      else
        -- Fungible: quantity ledger, optional oversell block.
        if v_block then
          select coalesce(sum(qty), 0) into v_onhand from inventory_txns where product_id = v_product;
          if v_onhand < v_qty then
            raise exception 'Not enough stock for product % (% on hand, % requested)', v_product, v_onhand, v_qty;
          end if;
        end if;
        insert into sale_lines (sale_id, product_id, qty, unit_price) values (v_sale_id, v_product, v_qty, v_price);
        insert into inventory_txns (txn_type, product_id, qty, sale_id) values ('sell', v_product, -v_qty, v_sale_id);
      end if;
      v_taxable := v_taxable + v_line_total;

    elsif v_job is not null then
      select status, paid_sale_id into v_job_status, v_job_paid from string_jobs where id = v_job;
      if not found then
        raise exception 'Unknown string_job_id % in sale line', v_job;
      end if;
      if v_job_status = 'cancelled' then
        raise exception 'String job % was cancelled and can''t be charged', v_job;
      end if;
      if v_job_paid = v_sale_id then
        raise exception 'String job % is on this ticket more than once', v_job;
      end if;
      if v_job_paid is not null then
        raise exception 'String job % is already paid (sale %)', v_job, v_job_paid;
      end if;
      insert into sale_lines (sale_id, string_job_id, qty, unit_price) values (v_sale_id, v_job, v_qty, v_price);
      update string_jobs set paid_sale_id = v_sale_id where id = v_job;
      if v_tax_string then v_taxable := v_taxable + v_line_total; end if;

    else
      if not exists (select 1 from gift_cards where id = v_gc) then
        raise exception 'Unknown gift_card_id % in sale line', v_gc;
      end if;
      select coalesce(sum(amount), 0) into v_prev from gift_card_txns where gift_card_id = v_gc;
      insert into sale_lines (sale_id, gift_card_id, qty, unit_price) values (v_sale_id, v_gc, v_qty, v_price);
      insert into gift_card_txns (gift_card_id, amount, reason, sale_id) values (v_gc, v_line_total, 'load', v_sale_id);
      if v_prev <= 0 then update gift_cards set customer_id = p_customer_id where id = v_gc; end if;
    end if;

    v_subtotal := v_subtotal + v_line_total;
  end loop;

  v_tax := round(v_taxable * v_rate / 100.0, 2);

  if p_payments is not null then
    for v_pay in select * from jsonb_array_elements(p_payments)
    loop
      v_method := v_pay->>'method';
      v_amount := (v_pay->>'amount')::numeric;
      v_gc     := nullif(v_pay->>'gift_card_id', '')::uuid;

      if v_amount is null or v_amount <= 0 then raise exception 'Payment amount must be positive'; end if;
      if v_method not in ('cash', 'credit', 'gift_card', 'store_credit') then raise exception 'Invalid payment method "%"', v_method; end if;

      if v_method = 'gift_card' then
        if v_gc is null then raise exception 'Gift card payment needs a gift_card_id'; end if;
        select coalesce(sum(amount), 0) into v_bal from gift_card_txns where gift_card_id = v_gc;
        if v_bal < v_amount then raise exception 'Gift card balance % is less than %', v_bal, v_amount; end if;
        insert into gift_card_txns (gift_card_id, amount, reason, sale_id) values (v_gc, -v_amount, 'redeem', v_sale_id);
        insert into sale_payments (sale_id, method, amount, gift_card_id) values (v_sale_id, 'gift_card', v_amount, v_gc);
        select coalesce(sum(amount), 0) into v_bal from gift_card_txns where gift_card_id = v_gc;
        if v_bal <= 0 then update gift_cards set customer_id = null where id = v_gc; end if;
      elsif v_method = 'store_credit' then
        if p_customer_id is null then raise exception 'Store credit needs a customer on the sale'; end if;
        select coalesce(sum(amount), 0) into v_bal from store_credit_txns where customer_id = p_customer_id;
        if v_bal < v_amount then raise exception 'Store credit balance % is less than %', v_bal, v_amount; end if;
        insert into store_credit_txns (customer_id, amount, reason, sale_id) values (p_customer_id, -v_amount, 'redeem', v_sale_id);
        insert into sale_payments (sale_id, method, amount) values (v_sale_id, 'store_credit', v_amount);
      else
        insert into sale_payments (sale_id, method, amount) values (v_sale_id, v_method, v_amount);
      end if;

      v_paid := v_paid + v_amount;
    end loop;
  end if;

  if abs(v_paid - (v_subtotal + v_tax)) > 0.005 then
    raise exception 'Payments (%) must equal the sale total (%)', v_paid, v_subtotal + v_tax;
  end if;

  select count(*) into v_count from sale_payments where sale_id = v_sale_id;
  update sales
     set subtotal = v_subtotal,
         tax = v_tax,
         tax_rate = v_rate,
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

-- ----------------------------------------------------------------------------
-- 4. record_refund — same as 0032, plus: the sale is locked (refunds of one
--    sale run one at a time), tax is cumulative and capped at the sale's tax,
--    and payment-type changes need a reason.
-- ----------------------------------------------------------------------------
drop function if exists record_refund(uuid, jsonb, jsonb, text, text);

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
security invoker
as $$
declare
  v_refund_id  uuid := gen_random_uuid();
  v_customer   uuid;
  v_rate       numeric := 0;
  v_sale_tax   numeric := 0;
  v_prev_sub   numeric := 0;
  v_prev_tax   numeric := 0;
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
  v_by_method  record;
  v_changed    text[] := '{}';
begin
  -- Locking the sale serializes refunds of the same sale, so remaining
  -- quantities, tax and per-method amounts below can't be raced.
  select customer_id, coalesce(tax_rate, 0), coalesce(tax, 0)
    into v_customer, v_rate, v_sale_tax
    from sales where id = p_sale_id
    for update;
  if not found then raise exception 'Unknown sale %', p_sale_id; end if;
  if p_lines is null or jsonb_array_length(p_lines) = 0 then raise exception 'A refund needs at least one line'; end if;

  select coalesce(sum(subtotal), 0), coalesce(sum(tax), 0)
    into v_prev_sub, v_prev_tax
    from refunds where sale_id = p_sale_id;

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
    if v_sl.product_unit_id is not null then
      raise exception 'Returning individual (serialized) items is not supported yet';
    end if;

    select coalesce(sum(rl.qty), 0) into v_returned from refund_lines rl where rl.sale_line_id = v_sl_id;
    if v_qty > v_sl.qty - v_returned then
      raise exception 'Cannot return % of line (only % remaining)', v_qty, v_sl.qty - v_returned;
    end if;

    insert into refund_lines (refund_id, sale_line_id, qty, unit_price)
    values (v_refund_id, v_sl_id, v_qty, v_sl.unit_price);

    -- Returned stock goes back on hand.
    insert into inventory_txns (txn_type, product_id, qty, sale_id)
    values ('return', v_sl.product_id, v_qty, p_sale_id);

    v_sub := v_sub + v_qty * v_sl.unit_price;
  end loop;

  -- Tax on everything refunded so far (rounded once), minus tax already
  -- refunded, never beyond what the sale charged.
  v_tax   := greatest(0, least(round((v_prev_sub + v_sub) * v_rate / 100.0, 2), v_sale_tax) - v_prev_tax);
  v_total := v_sub + v_tax;
  update refunds set subtotal = v_sub, tax = v_tax where id = v_refund_id;

  if p_payments is not null then
    for v_pay in select * from jsonb_array_elements(p_payments)
    loop
      v_method := v_pay->>'method';
      v_amount := (v_pay->>'amount')::numeric;
      v_gc     := nullif(v_pay->>'gift_card_id', '')::uuid;
      if v_amount is null or v_amount <= 0 then raise exception 'Refund amount must be positive'; end if;
      if v_method not in ('cash', 'credit', 'gift_card', 'store_credit') then raise exception 'Invalid refund method "%"', v_method; end if;

      if v_method = 'gift_card' then
        if v_gc is null then raise exception 'Gift card refund needs a gift_card_id'; end if;
        insert into gift_card_txns (gift_card_id, amount, reason, sale_id) values (v_gc, v_amount, 'refund', p_sale_id);
      elsif v_method = 'store_credit' then
        if v_customer is null then raise exception 'Store credit refund needs a customer on the sale'; end if;
        insert into store_credit_txns (customer_id, amount, reason, sale_id) values (v_customer, v_amount, 'refund', p_sale_id);
      end if;

      insert into refund_payments (refund_id, method, amount, gift_card_id) values (v_refund_id, v_method, v_amount, v_gc);
      v_paid := v_paid + v_amount;
    end loop;
  end if;

  if abs(v_paid - v_total) > 0.005 then
    raise exception 'Refund payments (%) must equal the refund total (%)', v_paid, v_total;
  end if;

  -- Each payment type can give back what the sale took that way, net of earlier
  -- refunds. A type this refund sends more to than that is a payment-type
  -- change and needs a reason. (Only types this refund pays out to count, so an
  -- earlier, already-explained change doesn't follow later refunds around.)
  for v_by_method in
    select m.method,
           coalesce((select sum(sp.amount) from sale_payments sp
                      where sp.sale_id = p_sale_id and sp.method = m.method), 0) as taken,
           coalesce((select sum(rp.amount) from refund_payments rp join refunds r on r.id = rp.refund_id
                      where r.sale_id = p_sale_id and r.id <> v_refund_id and rp.method = m.method), 0) as given_back_before,
           coalesce((select sum(rp.amount) from refund_payments rp
                      where rp.refund_id = v_refund_id and rp.method = m.method), 0) as this_refund
    from (values ('cash'), ('credit'), ('gift_card'), ('store_credit')) as m(method)
  loop
    if v_by_method.this_refund > 0
       and v_by_method.this_refund > greatest(v_by_method.taken - v_by_method.given_back_before, 0) + 0.005 then
      v_changed := v_changed || v_by_method.method;
    end if;
  end loop;

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

grant execute on function record_refund(uuid, jsonb, jsonb, text, text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. adjust_gift_card — same as 0026, but locks the card so a concurrent
--    redemption can't slip between the balance check and the adjustment.
-- ----------------------------------------------------------------------------
create or replace function adjust_gift_card(p_gift_card_id uuid, p_amount numeric, p_reason text)
returns numeric
language plpgsql
security invoker
as $$
declare
  v_bal numeric;
begin
  if p_amount is null or p_amount = 0 then
    raise exception 'Adjustment amount must be non-zero';
  end if;
  perform 1 from gift_cards where id = p_gift_card_id for update;
  if not found then
    raise exception 'Unknown gift card %', p_gift_card_id;
  end if;

  select coalesce(sum(amount), 0) into v_bal from gift_card_txns where gift_card_id = p_gift_card_id;
  if v_bal + p_amount < 0 then
    raise exception 'Adjustment would make the balance negative (balance %, adjustment %)', v_bal, p_amount;
  end if;

  insert into gift_card_txns (gift_card_id, amount, reason)
  values (p_gift_card_id, p_amount, coalesce(nullif(trim(p_reason), ''), 'adjust'));

  v_bal := v_bal + p_amount;
  if v_bal <= 0 then
    update gift_cards set customer_id = null where id = p_gift_card_id;
  end if;
  return v_bal;
end;
$$;

grant execute on function adjust_gift_card(uuid, numeric, text) to authenticated;
