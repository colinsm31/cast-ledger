-- =============================================================================
-- 0030_refunds.sql — returns, refunds, and voids (AceStock)
--
-- A refund reverses part or all of a sale: return chosen product lines (which
-- restock inventory) and give the money back via a tender — cash/credit, issued
-- store credit, or value loaded onto a gift card. A "void" is just a full refund
-- of everything to the original tenders. Refunds flow into the sales report so
-- net receipts reflect money actually kept.
--
-- v1 scope: only product lines are returnable (services / gift-card sales are
-- not). Re-runnable.
-- =============================================================================

-- Allow a 'return' inventory txn (returned stock goes back on hand).
alter table inventory_txns drop constraint if exists inventory_txns_txn_type_check;
alter table inventory_txns
  add constraint inventory_txns_txn_type_check
  check (txn_type in ('receive', 'adjust', 'sell', 'transfer', 'consume', 'return'));

-- Record the tax rate applied to a sale, so a later refund taxes returned lines
-- at the original rate regardless of settings changes.
alter table sales add column if not exists tax_rate numeric(6, 3) not null default 0;

-- ----------------------------------------------------------------------------
-- Refund tables
-- ----------------------------------------------------------------------------
create table if not exists refunds (
  id          uuid primary key default gen_random_uuid(),
  sale_id     uuid not null references sales (id),
  subtotal    numeric(12, 2) not null default 0,
  tax         numeric(12, 2) not null default 0,
  reason      text,
  note        text,
  refunded_at timestamptz not null default now(),
  created_at  timestamptz not null default now()
);
create index if not exists idx_refunds_sale on refunds (sale_id);

create table if not exists refund_lines (
  id           uuid primary key default gen_random_uuid(),
  refund_id    uuid not null references refunds (id) on delete cascade,
  sale_line_id uuid not null references sale_lines (id),
  qty          integer not null check (qty > 0),
  unit_price   numeric(12, 2) not null
);
create index if not exists idx_refund_lines_refund on refund_lines (refund_id);
create index if not exists idx_refund_lines_saleline on refund_lines (sale_line_id);

create table if not exists refund_payments (
  id           uuid primary key default gen_random_uuid(),
  refund_id    uuid not null references refunds (id) on delete cascade,
  method       text not null check (method in ('cash', 'credit', 'gift_card', 'store_credit')),
  amount       numeric(12, 2) not null check (amount > 0),
  gift_card_id uuid references gift_cards (id),
  created_at   timestamptz not null default now()
);
create index if not exists idx_refund_payments_refund on refund_payments (refund_id);

alter table refunds         enable row level security;
alter table refund_lines    enable row level security;
alter table refund_payments enable row level security;
do $$
declare tbl text;
begin
  foreach tbl in array array['refunds','refund_lines','refund_payments'] loop
    execute format('drop policy if exists %I on %I', tbl||'_authenticated_all', tbl);
    execute format('create policy %I on %I for all to authenticated using (true) with check (true)', tbl||'_authenticated_all', tbl);
  end loop;
end $$;
grant select, insert, update, delete on refunds, refund_lines, refund_payments to authenticated;

-- ----------------------------------------------------------------------------
-- record_sale — unchanged behavior, now also stores the applied tax_rate.
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
      if not exists (select 1 from products where id = v_product) then
        raise exception 'Unknown product_id % in sale line', v_product;
      end if;
      if v_block then
        select coalesce(sum(qty), 0) into v_onhand from inventory_txns where product_id = v_product;
        if v_onhand < v_qty then
          raise exception 'Not enough stock for product % (% on hand, % requested)', v_product, v_onhand, v_qty;
        end if;
      end if;
      insert into sale_lines (sale_id, product_id, qty, unit_price) values (v_sale_id, v_product, v_qty, v_price);
      insert into inventory_txns (txn_type, product_id, qty, sale_id) values ('sell', v_product, -v_qty, v_sale_id);
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

-- ----------------------------------------------------------------------------
-- record_refund — return product lines from a sale + give money back.
--   p_lines:    [{sale_line_id, qty}]  (product lines only)
--   p_payments: [{method, amount, gift_card_id?}]  summing to refund total
-- ----------------------------------------------------------------------------
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

-- ----------------------------------------------------------------------------
-- sales_summary — net refunds out of receipts and per-tender totals.
-- ----------------------------------------------------------------------------
create or replace function sales_summary(p_from timestamptz, p_to timestamptz)
returns table (
  gross         numeric,
  tax           numeric,
  refunds       numeric,
  net           numeric,
  card          numeric,
  cash          numeric,
  check_amt     numeric,
  store_credit  numeric,
  gift_card     numeric,
  num_customers integer,
  num_tickets   integer,
  num_items     integer
)
language sql
security invoker
as $$
  with s as (
    select id, subtotal, tax, customer_id from sales where sold_at >= p_from and sold_at < p_to
  ),
  pay as (select sp.method, sp.amount from sale_payments sp join s on s.id = sp.sale_id),
  r as (select id, subtotal, tax from refunds where refunded_at >= p_from and refunded_at < p_to),
  rpay as (select rp.method, rp.amount from refund_payments rp join r on r.id = rp.refund_id)
  select
    coalesce((select sum(subtotal) from s), 0)                                                  as gross,
    coalesce((select sum(tax) from s), 0)                                                       as tax,
    coalesce((select sum(subtotal + tax) from r), 0)                                            as refunds,
    coalesce((select sum(subtotal) from s), 0) + coalesce((select sum(tax) from s), 0)
      - coalesce((select sum(subtotal + tax) from r), 0)                                        as net,
    coalesce((select sum(amount) from pay where method = 'credit'), 0)
      - coalesce((select sum(amount) from rpay where method = 'credit'), 0)                     as card,
    coalesce((select sum(amount) from pay where method = 'cash'), 0)
      - coalesce((select sum(amount) from rpay where method = 'cash'), 0)                       as cash,
    0::numeric                                                                                  as check_amt,
    coalesce((select sum(amount) from pay where method = 'store_credit'), 0)
      - coalesce((select sum(amount) from rpay where method = 'store_credit'), 0)               as store_credit,
    coalesce((select sum(amount) from pay where method = 'gift_card'), 0)
      - coalesce((select sum(amount) from rpay where method = 'gift_card'), 0)                  as gift_card,
    (select count(distinct customer_id) from s where customer_id is not null)::int              as num_customers,
    (select count(*) from s)::int                                                               as num_tickets,
    coalesce((select sum(sl.qty) from sale_lines sl join s on s.id = sl.sale_id
              where sl.product_id is not null), 0)::int                                         as num_items;
$$;
grant execute on function sales_summary(timestamptz, timestamptz) to authenticated;
