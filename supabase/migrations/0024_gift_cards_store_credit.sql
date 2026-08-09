-- =============================================================================
-- 0024_gift_cards_store_credit.sql — gift cards, store credit, split tender
--
-- Gift cards (anonymous or tied to a customer) and per-customer store credit are
-- account-backed balances tracked as append-only ledgers, like inventory. A sale
-- can be paid with a mix of tenders (split payment) recorded in sale_payments.
-- Selling/loading a gift card is a sale line that credits the card; paying with
-- a gift card or store credit redeems from the balance.
--
-- Re-runnable.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- Gift cards
-- ----------------------------------------------------------------------------
create table if not exists gift_cards (
  id          uuid primary key default gen_random_uuid(),
  code        text not null,
  customer_id uuid references customers (id),   -- null = anonymous
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create unique index if not exists uq_gift_cards_code on gift_cards (code);

create table if not exists gift_card_txns (
  id           uuid primary key default gen_random_uuid(),
  gift_card_id uuid not null references gift_cards (id),
  amount       numeric(12, 2) not null,          -- + load, − redeem
  reason       text,
  sale_id      uuid references sales (id),
  created_at   timestamptz not null default now()
);
create index if not exists idx_gift_card_txns_card on gift_card_txns (gift_card_id);

create or replace view gift_card_balance as
select gc.id as gift_card_id, gc.code, gc.customer_id,
       coalesce(sum(t.amount), 0)::numeric as balance
from gift_cards gc
left join gift_card_txns t on t.gift_card_id = gc.id
group by gc.id, gc.code, gc.customer_id;

-- ----------------------------------------------------------------------------
-- Store credit (per customer)
-- ----------------------------------------------------------------------------
create table if not exists store_credit_txns (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers (id) on delete cascade,
  amount      numeric(12, 2) not null,           -- + issue, − redeem
  reason      text,
  sale_id     uuid references sales (id),
  created_at  timestamptz not null default now()
);
create index if not exists idx_store_credit_txns_customer on store_credit_txns (customer_id);

create or replace view customer_store_credit as
select c.id as customer_id, coalesce(sum(t.amount), 0)::numeric as balance
from customers c
left join store_credit_txns t on t.customer_id = c.id
group by c.id;

-- ----------------------------------------------------------------------------
-- Split tender: payments per sale
-- ----------------------------------------------------------------------------
create table if not exists sale_payments (
  id           uuid primary key default gen_random_uuid(),
  sale_id      uuid not null references sales (id) on delete cascade,
  method       text not null check (method in ('cash', 'credit', 'gift_card', 'store_credit')),
  amount       numeric(12, 2) not null check (amount > 0),
  gift_card_id uuid references gift_cards (id),   -- set for gift_card tenders
  created_at   timestamptz not null default now()
);
create index if not exists idx_sale_payments_sale on sale_payments (sale_id);

-- ----------------------------------------------------------------------------
-- sale_lines: a line references a product, a string job, OR a gift-card load.
-- ----------------------------------------------------------------------------
alter table sale_lines add column if not exists gift_card_id uuid references gift_cards (id);
alter table sale_lines drop constraint if exists sale_lines_one_ref;
alter table sale_lines
  add constraint sale_lines_one_ref check (
    (case when product_id     is null then 0 else 1 end) +
    (case when string_job_id  is null then 0 else 1 end) +
    (case when gift_card_id    is null then 0 else 1 end) = 1
  );

-- payment_method summary may now be 'split'.
alter table sales drop constraint if exists sales_payment_method_check;
alter table sales
  add constraint sales_payment_method_check
  check (payment_method is null or payment_method in ('credit', 'cash', 'gift_card', 'store_credit', 'split'));

-- ----------------------------------------------------------------------------
-- RLS + grants for the new tables/views
-- ----------------------------------------------------------------------------
alter table gift_cards        enable row level security;
alter table gift_card_txns    enable row level security;
alter table store_credit_txns enable row level security;
alter table sale_payments     enable row level security;

do $$
declare tbl text;
begin
  foreach tbl in array array['gift_cards','gift_card_txns','store_credit_txns','sale_payments'] loop
    execute format('drop policy if exists %I on %I', tbl||'_authenticated_all', tbl);
    execute format('create policy %I on %I for all to authenticated using (true) with check (true)', tbl||'_authenticated_all', tbl);
  end loop;
end $$;

grant select, insert, update, delete on gift_cards, gift_card_txns, store_credit_txns, sale_payments to authenticated;
grant select on gift_card_balance, customer_store_credit to authenticated;

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

-- ensure_gift_card — get (or create) a card by code; returns its id.
create or replace function ensure_gift_card(p_code text, p_customer_id uuid)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_id uuid;
begin
  if coalesce(trim(p_code), '') = '' then
    raise exception 'Gift card code required';
  end if;
  insert into gift_cards (code, customer_id)
  values (trim(p_code), p_customer_id)
  on conflict (code) do nothing;
  select id into v_id from gift_cards where code = trim(p_code);
  return v_id;
end;
$$;
grant execute on function ensure_gift_card(text, uuid) to authenticated;

-- add_store_credit — issue store credit to a customer; returns new balance.
create or replace function add_store_credit(p_customer_id uuid, p_amount numeric, p_reason text)
returns numeric
language plpgsql
security invoker
as $$
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'Store credit amount must be positive';
  end if;
  if not exists (select 1 from customers where id = p_customer_id) then
    raise exception 'Unknown customer %', p_customer_id;
  end if;
  insert into store_credit_txns (customer_id, amount, reason)
  values (p_customer_id, p_amount, nullif(trim(p_reason), ''));
  return (select coalesce(sum(amount), 0) from store_credit_txns where customer_id = p_customer_id);
end;
$$;
grant execute on function add_store_credit(uuid, numeric, text) to authenticated;

-- ----------------------------------------------------------------------------
-- record_sale — split tender. Lines: product / string job / gift-card load.
-- Payments: [{method, amount, gift_card_id?}] summing to the subtotal.
-- ----------------------------------------------------------------------------
drop function if exists record_sale(jsonb, uuid, text, text);
drop function if exists record_sale(jsonb, uuid, text);

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
      insert into sale_lines (sale_id, gift_card_id, qty, unit_price)
      values (v_sale_id, v_gc, v_qty, v_price);
      -- Loading value onto the card.
      insert into gift_card_txns (gift_card_id, amount, reason, sale_id)
      values (v_gc, v_qty * v_price, 'load', v_sale_id);
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
