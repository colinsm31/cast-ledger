-- =============================================================================
-- 0032_serialized_units.sql — serialized inventory (individual rackets) (AceStock)
--
-- Adds a second inventory level for items tracked as individual physical units
-- (rackets/paddles). Level 1 stays the catalog product (one row per model+grip,
-- carrying the UPC in products.barcode and the shared price). Level 2 is a new
-- product_units table: each physical unit has its own personal shop barcode and a
-- status, and can be attached to a customer (sold-to or demo loan, later).
--
-- Stock split: for a serialized product, on-hand is the count of in_stock units;
-- for everything else it stays the inventory_txns quantity sum. record_sale sells
-- a specific unit (by product_unit_id) instead of writing a 'sell' ledger txn.
--
-- Re-runnable.
-- =============================================================================

-- 1. Flag: which products are tracked as individual serialized units.
alter table products
  add column if not exists is_serialized boolean not null default false;

-- 2. Serialized units. One row per physical item, keyed to its catalog product.
create table if not exists product_units (
  id           uuid primary key default gen_random_uuid(),
  product_id   uuid not null references products (id),
  barcode      text,                             -- personal shop barcode (per unit; optional)
  status       text not null default 'in_stock'
                 check (status in ('in_stock', 'sold', 'demo', 'assigned', 'retired')),
  customer_id  uuid references customers (id),   -- sold-to or demo borrower (nullable)
  sale_id      uuid references sales (id),       -- the sale that sold this unit (nullable)
  note         text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Personal barcode is optional, but unique when present.
create unique index if not exists uq_product_units_barcode
  on product_units (barcode) where barcode is not null;
create index if not exists idx_product_units_product on product_units (product_id);
create index if not exists idx_product_units_status on product_units (status);

alter table product_units enable row level security;
drop policy if exists product_units_authenticated_all on product_units;
create policy product_units_authenticated_all on product_units
  for all to authenticated using (true) with check (true);
grant select, insert, update, delete on product_units to authenticated;

-- 3. Sale lines can reference the exact physical unit sold.
alter table sale_lines
  add column if not exists product_unit_id uuid references product_units (id);

-- =============================================================================
-- 4. product_stock — serialized products count in_stock units; others sum ledger.
-- =============================================================================
create or replace view product_stock as
select
  p.id as product_id,
  case
    when p.is_serialized then (
      select count(*) from product_units u
      where u.product_id = p.id and u.status = 'in_stock'
    )::numeric
    else coalesce((select sum(t.qty) from inventory_txns t where t.product_id = p.id), 0)::numeric
  end as on_hand,
  p.reorder_point,
  (
    p.reorder_point is not null
    and (
      case
        when p.is_serialized then (
          select count(*) from product_units u
          where u.product_id = p.id and u.status = 'in_stock'
        )
        else coalesce((select sum(t.qty) from inventory_txns t where t.product_id = p.id), 0)
      end
    ) <= p.reorder_point
  ) as is_low
from products p;

grant select on product_stock to authenticated;

-- =============================================================================
-- 5. record_sale — a serialized product line consumes a specific unit.
--    Same signature as 0030; product lines may now carry "product_unit_id".
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
  v_sale_id     uuid := gen_random_uuid();
  v_line        jsonb;
  v_pay         jsonb;
  v_product     uuid;
  v_unit        uuid;
  v_serialized  boolean;
  v_job         uuid;
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
          from product_units where id = v_unit for update;
        if v_unit_status is null then raise exception 'Unknown product_unit_id %', v_unit; end if;
        if v_unit_prod <> v_product then raise exception 'Unit % does not belong to product %', v_unit, v_product; end if;
        if v_unit_status <> 'in_stock' then raise exception 'Unit % is not in stock (status %)', v_unit, v_unit_status; end if;

        insert into sale_lines (sale_id, product_id, product_unit_id, qty, unit_price)
        values (v_sale_id, v_product, v_unit, v_qty, v_price);
        update product_units
           set status = 'sold', sale_id = v_sale_id, customer_id = p_customer_id, updated_at = now()
         where id = v_unit;
      else
        -- Fungible: quantity ledger, optional oversell block (unchanged behavior).
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
      if not exists (select 1 from string_jobs where id = v_job) then
        raise exception 'Unknown string_job_id % in sale line', v_job;
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

-- =============================================================================
-- 6. record_refund — guard: serialized (unit) lines can't be returned yet.
--    Returning a physical racket must flip its unit back to in_stock; that flow
--    is a planned follow-up, so block it here to protect data integrity rather
--    than post a meaningless stock txn. Same signature as 0030.
-- =============================================================================
create or replace function record_refund(
  p_sale_id  uuid,
  p_lines    jsonb,
  p_payments jsonb,
  p_reason   text,
  p_note     text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_refund_id uuid := gen_random_uuid();
  v_customer  uuid;
  v_rate      numeric := 0;
  v_line      jsonb;
  v_pay       jsonb;
  v_sl_id     uuid;
  v_qty       integer;
  v_sl        record;
  v_returned  integer;
  v_sub       numeric := 0;
  v_tax       numeric := 0;
  v_total     numeric := 0;
  v_paid      numeric := 0;
  v_method    text;
  v_amount    numeric;
  v_gc        uuid;
begin
  select customer_id, coalesce(tax_rate, 0) into v_customer, v_rate from sales where id = p_sale_id;
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

  v_tax   := round(v_sub * v_rate / 100.0, 2);
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

  return v_refund_id;
end;
$$;
grant execute on function record_refund(uuid, jsonb, jsonb, text, text) to authenticated;

-- =============================================================================
-- 7. receive_units — add physical units to a serialized product.
--    p_barcodes is a JSON array with one element per unit received; each element
--    is the unit's personal barcode, or null/"" for a unit with no barcode yet
--    (barcode is optional). Rejects a barcode already used by another unit.
--    Returns the number of units created.
-- =============================================================================
create or replace function receive_units(
  p_product_id uuid,
  p_barcodes   jsonb
)
returns integer
language plpgsql
security invoker
as $$
declare
  v_serialized boolean;
  v_el         jsonb;
  v_code       text;
  v_count      integer := 0;
begin
  select is_serialized into v_serialized from products where id = p_product_id;
  if v_serialized is null then raise exception 'Unknown product_id %', p_product_id; end if;
  if not v_serialized then raise exception 'Product % is not serialized', p_product_id; end if;
  if p_barcodes is null or jsonb_array_length(p_barcodes) = 0 then
    raise exception 'Receive at least one unit';
  end if;

  for v_el in select * from jsonb_array_elements(p_barcodes)
  loop
    -- '#>> {}' pulls the scalar text out of a jsonb element (string or null).
    v_code := nullif(btrim(coalesce(v_el #>> '{}', '')), '');
    if v_code is not null and exists (select 1 from product_units where barcode = v_code) then
      raise exception 'Barcode % is already in use', v_code;
    end if;
    insert into product_units (product_id, barcode) values (p_product_id, v_code);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
grant execute on function receive_units(uuid, jsonb) to authenticated;

-- =============================================================================
-- 8. resolve_barcode — now also resolves a serialized unit's personal barcode
--    and reports whether a matched product is serialized. Resolution order:
--    product UPC -> product unit -> customer racket -> gift card -> none. Return
--    type changes (new product_id + unit_status columns), so drop and recreate.
-- =============================================================================
drop function if exists resolve_barcode(text);
create or replace function resolve_barcode(p_code text)
returns table (
  kind          text,
  code          text,
  id            uuid,      -- the matched thing's id (product / unit / racket / gift card)
  product_id    uuid,      -- for a unit: its catalog product; else null
  customer_id   uuid,
  open_job_id   uuid,
  brand         text,
  name          text,
  attributes    jsonb,
  sell_price    numeric,
  is_serialized boolean,
  unit_status   text       -- for a unit: its status; else null
)
language plpgsql
security invoker
stable
as $$
declare
  v_code       text := regexp_replace(coalesce(p_code, ''), '\s+', '', 'g');
  v_candidates text[];
  v_product    products%rowtype;
  v_unit       product_units%rowtype;
  v_racket     customer_rackets%rowtype;
  v_gift_card  gift_cards%rowtype;
begin
  if v_code = '' then
    return query select 'none', v_code, null::uuid, null::uuid, null::uuid, null::uuid,
                        null::text, null::text, null::jsonb, null::numeric, false, null::text;
    return;
  end if;

  v_candidates := array[v_code];
  if v_code ~ '^0[0-9]{12}$' then
    v_candidates := v_candidates || substr(v_code, 2);
  elsif v_code ~ '^[0-9]{12}$' then
    v_candidates := v_candidates || ('0' || v_code);
  end if;

  -- Product UPC.
  select * into v_product from products p where p.barcode = any (v_candidates) limit 1;
  if found then
    return query select 'product', v_product.barcode, v_product.id, null::uuid, null::uuid, null::uuid,
                        v_product.brand, v_product.name, v_product.attributes, v_product.sell_price,
                        v_product.is_serialized, null::text;
    return;
  end if;

  -- Individual unit's personal barcode.
  select * into v_unit from product_units u where u.barcode = any (v_candidates) limit 1;
  if found then
    select * into v_product from products p where p.id = v_unit.product_id;
    return query select 'unit', v_unit.barcode, v_unit.id, v_unit.product_id, null::uuid, null::uuid,
                        v_product.brand, v_product.name, v_product.attributes, v_product.sell_price,
                        true, v_unit.status;
    return;
  end if;

  select * into v_racket from customer_rackets r where r.barcode = any (v_candidates) limit 1;
  if found then
    return query select 'racket', v_racket.barcode, v_racket.id, null::uuid, v_racket.customer_id,
                        (select j.id from string_jobs j
                          where j.customer_racket_id = v_racket.id
                            and j.status in ('entered', 'complete')
                          order by j.entered_at desc limit 1),
                        null::text, null::text, null::jsonb, null::numeric, false, null::text;
    return;
  end if;

  select * into v_gift_card from gift_cards g where g.code = any (v_candidates) limit 1;
  if found then
    return query select 'gift_card', v_gift_card.code, v_gift_card.id, null::uuid, v_gift_card.customer_id, null::uuid,
                        null::text, null::text, null::jsonb, null::numeric, false, null::text;
    return;
  end if;

  return query select 'none', v_code, null::uuid, null::uuid, null::uuid, null::uuid,
                      null::text, null::text, null::jsonb, null::numeric, false, null::text;
end;
$$;
grant execute on function resolve_barcode(text) to authenticated;
