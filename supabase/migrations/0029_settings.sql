-- =============================================================================
-- 0029_settings.sql — shop settings: tax, stringing labor, inventory, reports
--
-- A single-row settings table drives checkout tax, the stringing base labor
-- charge, inventory defaults/oversell, and the report week start. record_sale
-- now charges tax on taxable lines (products always; stringing optionally; gift
-- card loads never) and can block selling below zero stock.
--
-- Re-runnable.
-- =============================================================================

create table if not exists settings (
  id                    boolean primary key default true check (id),
  tax_rate              numeric(6, 3) not null default 0,     -- percent, e.g. 8.25
  tax_stringing         boolean not null default false,       -- is stringing labor/service taxed?
  stringing_labor       numeric(12, 2) not null default 0,    -- base labor added to string price
  default_reorder_point integer,                              -- prefill for new products (null = none)
  block_oversell        boolean not null default false,       -- refuse selling below 0 on hand
  week_starts_monday    boolean not null default false,       -- report "week to date" boundary
  updated_at            timestamptz not null default now()
);
insert into settings (id) values (true) on conflict (id) do nothing;

alter table settings enable row level security;
drop policy if exists settings_authenticated_select on settings;
drop policy if exists settings_authenticated_update on settings;
create policy settings_authenticated_select on settings for select to authenticated using (true);
create policy settings_authenticated_update on settings for update to authenticated using (true) with check (true);
grant select, update on settings to authenticated;

-- Sale tax amount (total charged = subtotal + tax).
alter table sales add column if not exists tax numeric(12, 2) not null default 0;

-- ----------------------------------------------------------------------------
-- record_sale — now applies tax and (optionally) blocks overselling.
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
      insert into sale_lines (sale_id, product_id, qty, unit_price)
      values (v_sale_id, v_product, v_qty, v_price);
      insert into inventory_txns (txn_type, product_id, qty, sale_id)
      values ('sell', v_product, -v_qty, v_sale_id);
      v_taxable := v_taxable + v_line_total;              -- products are taxable
    elsif v_job is not null then
      if not exists (select 1 from string_jobs where id = v_job) then
        raise exception 'Unknown string_job_id % in sale line', v_job;
      end if;
      insert into sale_lines (sale_id, string_job_id, qty, unit_price)
      values (v_sale_id, v_job, v_qty, v_price);
      update string_jobs set paid_sale_id = v_sale_id where id = v_job;
      if v_tax_string then v_taxable := v_taxable + v_line_total; end if;
    else
      if not exists (select 1 from gift_cards where id = v_gc) then
        raise exception 'Unknown gift_card_id % in sale line', v_gc;
      end if;
      select coalesce(sum(amount), 0) into v_prev from gift_card_txns where gift_card_id = v_gc;
      insert into sale_lines (sale_id, gift_card_id, qty, unit_price)
      values (v_sale_id, v_gc, v_qty, v_price);
      insert into gift_card_txns (gift_card_id, amount, reason, sale_id)
      values (v_gc, v_line_total, 'load', v_sale_id);
      if v_prev <= 0 then
        update gift_cards set customer_id = p_customer_id where id = v_gc;
      end if;
      -- gift card loads are never taxed
    end if;

    v_subtotal := v_subtotal + v_line_total;
  end loop;

  v_tax := round(v_taxable * v_rate / 100.0, 2);

  -- Payments (split tender) must cover subtotal + tax.
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

  if abs(v_paid - (v_subtotal + v_tax)) > 0.005 then
    raise exception 'Payments (%) must equal the sale total (%)', v_paid, v_subtotal + v_tax;
  end if;

  select count(*) into v_count from sale_payments where sale_id = v_sale_id;
  update sales
     set subtotal = v_subtotal,
         tax = v_tax,
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
-- sales_summary — include tax; net receipts = gross + tax − refunds.
-- ----------------------------------------------------------------------------
drop function if exists sales_summary(timestamptz, timestamptz);
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
    select id, subtotal, tax, customer_id
    from sales
    where sold_at >= p_from and sold_at < p_to
  ),
  pay as (
    select sp.method, sp.amount from sale_payments sp join s on s.id = sp.sale_id
  )
  select
    coalesce((select sum(subtotal) from s), 0)                                             as gross,
    coalesce((select sum(tax) from s), 0)                                                  as tax,
    0::numeric                                                                             as refunds,
    coalesce((select sum(subtotal) from s), 0) + coalesce((select sum(tax) from s), 0)     as net,
    coalesce((select sum(amount) from pay where method = 'credit'), 0)                     as card,
    coalesce((select sum(amount) from pay where method = 'cash'), 0)                       as cash,
    0::numeric                                                                             as check_amt,
    coalesce((select sum(amount) from pay where method = 'store_credit'), 0)               as store_credit,
    coalesce((select sum(amount) from pay where method = 'gift_card'), 0)                  as gift_card,
    (select count(distinct customer_id) from s where customer_id is not null)::int         as num_customers,
    (select count(*) from s)::int                                                          as num_tickets,
    coalesce((select sum(sl.qty) from sale_lines sl join s on s.id = sl.sale_id
              where sl.product_id is not null), 0)::int                                    as num_items;
$$;
grant execute on function sales_summary(timestamptz, timestamptz) to authenticated;
