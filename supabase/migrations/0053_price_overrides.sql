-- =============================================================================
-- 0053_price_overrides.sql — a changed price at the register is recorded,
--                            with a reason (AceStock, Phase 2A)
--
-- Before:
--   • The register's line price was a free box. Whatever was typed was saved
--     as unit_price, with no record of the catalog price or why it changed.
--   • A string job charged at a different price silently took the new price.
--
-- Now:
--   1. sale_lines gains list_price (the catalog price, or the string job's
--      price, at the time of the sale; empty for gift card loads and items
--      with no catalog price) and price_reason. Who changed it is the sale's
--      "rung up by" (sales.user_id). Old sales stay empty.
--   2. sale_totals also returns each line's list_price, whether its price
--      changed, and the reason given. A price that differs from a list price,
--      up or down, is a change. No list price means nothing to change from.
--   3. require_sale_line limits a reason to 200 characters.
--   4. quote_sale lists a changed price without a reason as a problem, and
--      returns each line's list price so the register can pick up catalog
--      prices that changed while the ticket was open.
--   5. record_sale (carried over from 0052) saves list_price and the reason,
--      and refuses a changed price without one. A string job still takes the
--      price charged.
--   6. sales_summary gains price_changes (how many lines) and
--      price_change_total (what they added, negative when they took off). The
--      return type changes, so it's dropped and recreated with its grants.
--   7. Quick-pick reasons are seeded in lookup_values (kind 'price_reason');
--      the shop can add its own from the register.
--
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Columns
-- -----------------------------------------------------------------------------
alter table sale_lines add column if not exists list_price numeric(12, 2);
alter table sale_lines add column if not exists price_reason text;
alter table sale_lines drop constraint if exists ck_sale_lines_list_price;
alter table sale_lines add constraint ck_sale_lines_list_price check (list_price >= 0 and list_price <> 'NaN');
alter table sale_lines drop constraint if exists ck_sale_lines_price_reason;
alter table sale_lines add constraint ck_sale_lines_price_reason
  check (price_reason is null or (char_length(price_reason) between 1 and 200 and price_reason = trim(price_reason)));

comment on column sale_lines.list_price is 'Catalog price (or string job price) when sold; null for gift card loads and items without one';
comment on column sale_lines.price_reason is 'Why the price differs from list_price; set only when it does';

-- -----------------------------------------------------------------------------
-- 2. sale_totals — now with each line's list price and price change
-- -----------------------------------------------------------------------------
-- Returns
--   { lines: [{ line_total, taxable, list_price, price_changed, price_reason }],
--     subtotal, taxable, tax_rate, tax, total }
-- with lines in the same order as p_lines. price_reason is the trimmed reason
-- when the price changed, otherwise null. Doesn't validate: callers do.
create or replace function sale_totals(p_lines jsonb)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_rate       numeric;
  v_tax_string boolean;
  v_line       jsonb;
  v_line_total numeric;
  v_taxed      boolean;
  v_list       numeric;
  v_changed    boolean;
  v_lines      jsonb := '[]'::jsonb;
  v_subtotal   numeric := 0;
  v_taxable    numeric := 0;
  v_tax        numeric;
begin
  select tax_rate, tax_stringing into v_rate, v_tax_string from settings where id = true;
  v_rate       := coalesce(v_rate, 0);
  v_tax_string := coalesce(v_tax_string, false);

  for v_line in select value from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) with ordinality order by ordinality
  loop
    v_line_total := (v_line->>'qty')::integer * (v_line->>'unit_price')::numeric;
    v_taxed := case
      when nullif(v_line->>'product_id', '') is not null then true
      when nullif(v_line->>'string_job_id', '') is not null then v_tax_string
      else false
    end;
    v_list := case
      when nullif(v_line->>'product_id', '') is not null then
        (select sell_price from products where id = nullif(v_line->>'product_id', '')::uuid)
      when nullif(v_line->>'string_job_id', '') is not null then
        (select price from string_jobs where id = nullif(v_line->>'string_job_id', '')::uuid)
    end;
    v_changed := v_list is not null and (v_line->>'unit_price')::numeric <> v_list;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'line_total',    v_line_total,
      'taxable',       v_taxed,
      'list_price',    v_list,
      'price_changed', v_changed,
      'price_reason',  case when v_changed then nullif(trim(v_line->>'price_reason'), '') end));
    v_subtotal := v_subtotal + v_line_total;
    if v_taxed then v_taxable := v_taxable + v_line_total; end if;
  end loop;

  v_tax := round(v_taxable * v_rate / 100.0, 2);
  return jsonb_build_object(
    'lines',    v_lines,
    'subtotal', v_subtotal,
    'taxable',  v_taxable,
    'tax_rate', v_rate,
    'tax',      v_tax,
    'total',    v_subtotal + v_tax
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. require_sale_line — plus a limit on the reason's length
-- -----------------------------------------------------------------------------
create or replace function require_sale_line(p_line jsonb)
returns void
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_qty   integer := (p_line->>'qty')::integer;
  v_price numeric := (p_line->>'unit_price')::numeric;
begin
  if v_qty is null or v_qty <= 0 then raise exception 'Sale line quantity must be positive'; end if;
  if v_price is null or v_price < 0 then raise exception 'Sale line price must be >= 0'; end if;
  if (case when nullif(p_line->>'product_id', '') is null then 0 else 1 end)
   + (case when nullif(p_line->>'string_job_id', '') is null then 0 else 1 end)
   + (case when nullif(p_line->>'gift_card_id', '') is null then 0 else 1 end) <> 1 then
    raise exception 'A sale line must reference exactly one of product, string job, or gift card';
  end if;
  if char_length(trim(p_line->>'price_reason')) > 200 then
    raise exception 'A price change reason can be at most 200 characters';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. quote_sale — a changed price needs a reason
-- -----------------------------------------------------------------------------
-- Badly formed input raises, as record_sale does. Lines that are well formed
-- but can't be sold right now are listed in `problems` as { line, message },
-- line being the 0-based position in p_lines. A line with its own problem
-- isn't also asked for a price reason. Nothing is locked or written.
create or replace function quote_sale(p_lines jsonb, p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_line        jsonb;
  v_index       integer;
  v_problems    jsonb := '[]'::jsonb;
  v_problem     text;
  v_product     uuid;
  v_unit        uuid;
  v_job         uuid;
  v_gc          uuid;
  v_qty         integer;
  v_serialized  boolean;
  v_unit_status text;
  v_unit_prod   uuid;
  v_job_status  text;
  v_job_paid    uuid;
  v_block       boolean;
  v_short       record;
  v_totals      jsonb;
  v_priced      jsonb;
begin
  perform require_staff();
  perform require_cents_each(p_lines, 'unit_price', 'Price');
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'A sale needs at least one line';
  end if;
  if p_customer_id is not null
     and not exists (select 1 from customers where id = p_customer_id) then
    raise exception 'Unknown customer_id %', p_customer_id;
  end if;

  for v_line, v_index in select value, ordinality - 1 from jsonb_array_elements(p_lines) with ordinality
  loop
    perform require_sale_line(v_line);
  end loop;
  v_totals := sale_totals(p_lines);

  for v_line, v_index in select value, ordinality - 1 from jsonb_array_elements(p_lines) with ordinality
  loop
    v_product := nullif(v_line->>'product_id', '')::uuid;
    v_unit    := nullif(v_line->>'product_unit_id', '')::uuid;
    v_job     := nullif(v_line->>'string_job_id', '')::uuid;
    v_gc      := nullif(v_line->>'gift_card_id', '')::uuid;
    v_qty     := (v_line->>'qty')::integer;
    v_problem := null;

    if v_product is not null then
      select is_serialized into v_serialized from products where id = v_product;
      if v_serialized is null then
        v_problem := 'This item is no longer in the catalog';
      elsif v_serialized then
        select status, product_id into v_unit_status, v_unit_prod from product_units where id = v_unit;
        if v_unit is null then
          v_problem := 'This item is tracked by unit: scan the unit being sold';
        elsif v_qty <> 1 then
          v_problem := 'Items tracked by unit sell one per line';
        elsif v_unit_status is null then
          v_problem := 'This unit is no longer on file';
        elsif v_unit_prod <> v_product then
          v_problem := 'This unit belongs to a different product';
        elsif v_unit_status <> 'in_stock' then
          v_problem := format('This unit is no longer in stock (%s)', replace(v_unit_status, '_', ' '));
        end if;
      end if;

    elsif v_job is not null then
      select status, paid_sale_id into v_job_status, v_job_paid from string_jobs where id = v_job;
      if not found then
        v_problem := 'This string job is no longer on file';
      elsif v_qty <> 1 then
        v_problem := 'A string job is charged once per line';
      elsif v_job_status = 'cancelled' then
        v_problem := 'This string job was cancelled';
      elsif v_job_paid is not null then
        v_problem := 'This string job is already paid';
      elsif exists (select 1 from jsonb_array_elements(p_lines) with ordinality o(l, n)
                     where n - 1 < v_index and nullif(l->>'string_job_id', '')::uuid = v_job) then
        v_problem := 'This string job is on the ticket more than once';
      end if;

    elsif not exists (select 1 from gift_cards where id = v_gc) then
      v_problem := 'This gift card is no longer on file';
    end if;

    v_priced := v_totals->'lines'->v_index;
    if v_problem is null and (v_priced->>'price_changed')::boolean and v_priced->>'price_reason' is null then
      v_problem := format('Price changed from $%s: give a reason',
                          to_char((v_priced->>'list_price')::numeric, 'FM999999990.00'));
    end if;

    if v_problem is not null then
      v_problems := v_problems || jsonb_build_array(jsonb_build_object('line', v_index, 'message', v_problem));
    end if;
  end loop;

  -- Overselling blocked: everything of one product on the ticket, against what's
  -- on hand, reported on that product's first line.
  select block_oversell into v_block from settings where id = true;
  if v_block then
    for v_short in
      select t.product_id, min(t.n) - 1 as first_line, sum(t.qty) as wanted,
             (select coalesce(sum(qty), 0) from inventory_txns i where i.product_id = t.product_id) as on_hand
        from (select nullif(l->>'product_id', '')::uuid as product_id, (l->>'qty')::integer as qty, n
                from jsonb_array_elements(p_lines) with ordinality o(l, n)) t
        join products p on p.id = t.product_id and not p.is_serialized
       group by t.product_id
      having sum(t.qty) > (select coalesce(sum(qty), 0) from inventory_txns i where i.product_id = t.product_id)
       order by min(t.n)
    loop
      v_problems := v_problems || jsonb_build_array(jsonb_build_object(
        'line', v_short.first_line,
        'message', format('Not enough stock: %s on hand, %s on this ticket', trim_scale(v_short.on_hand), v_short.wanted)));
    end loop;
  end if;

  return v_totals || jsonb_build_object('problems', v_problems);
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. record_sale — same as 0052, and it saves each line's list price and reason
-- -----------------------------------------------------------------------------
create or replace function record_sale(
  p_lines       jsonb,
  p_customer_id uuid,
  p_payments    jsonb,
  p_note        text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
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
  v_index       integer;
  v_totals      jsonb;
  v_taxed       boolean;
  v_priced      jsonb;
  v_list        numeric;
  v_reason      text;
  v_subtotal    numeric;
  v_total       numeric;
  v_paid        numeric := 0;
  v_method      text;
  v_amount      numeric;
  v_bal         numeric;
  v_prev        numeric;
  v_onhand      numeric;
  v_count       integer;
  v_rate        numeric;
  v_block       boolean := false;
  v_tax         numeric;
  v_unit_status text;
  v_unit_prod   uuid;
begin
  perform require_cents_each(p_lines, 'unit_price', 'Price');
  perform require_cents_each(p_payments, 'amount', 'Payment amount');
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'A sale needs at least one line';
  end if;
  if p_customer_id is not null
     and not exists (select 1 from customers where id = p_customer_id) then
    raise exception 'Unknown customer_id %', p_customer_id;
  end if;

  select block_oversell into v_block from settings where id = true;

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

  -- The totals, and which lines are taxed, come from sale_totals: the same
  -- function quote_sale uses, so the total the register showed before payment
  -- is the total this sale requires.
  v_totals   := sale_totals(p_lines);
  v_subtotal := (v_totals->>'subtotal')::numeric;
  v_tax      := (v_totals->>'tax')::numeric;
  v_rate     := (v_totals->>'tax_rate')::numeric;
  v_total    := (v_totals->>'total')::numeric;

  insert into sales (id, customer_id, subtotal, note)
  values (v_sale_id, p_customer_id, 0, nullif(trim(p_note), ''));

  for v_line, v_index in select value, ordinality - 1 from jsonb_array_elements(p_lines) with ordinality
  loop
    v_product := nullif(v_line->>'product_id', '')::uuid;
    v_unit    := nullif(v_line->>'product_unit_id', '')::uuid;
    v_job     := nullif(v_line->>'string_job_id', '')::uuid;
    v_gc      := nullif(v_line->>'gift_card_id', '')::uuid;
    v_qty     := (v_line->>'qty')::integer;
    v_price   := (v_line->>'unit_price')::numeric;
    v_priced  := v_totals->'lines'->v_index;
    v_taxed   := (v_priced->>'taxable')::boolean;
    v_list    := (v_priced->>'list_price')::numeric;
    v_reason  := v_priced->>'price_reason';

    perform require_sale_line(v_line);

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

        insert into sale_lines (sale_id, product_id, product_unit_id, qty, unit_price, taxable, list_price, price_reason)
        values (v_sale_id, v_product, v_unit, v_qty, v_price, v_taxed, v_list, v_reason);
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
        insert into sale_lines (sale_id, product_id, qty, unit_price, taxable, list_price, price_reason)
        values (v_sale_id, v_product, v_qty, v_price, v_taxed, v_list, v_reason);
        insert into inventory_txns (txn_type, product_id, qty, sale_id) values ('sell', v_product, -v_qty, v_sale_id);
      end if;

    elsif v_job is not null then
      if v_qty <> 1 then
        raise exception 'A string job is charged once per line (qty must be 1)';
      end if;
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
      insert into sale_lines (sale_id, string_job_id, qty, unit_price, taxable, list_price, price_reason)
      values (v_sale_id, v_job, v_qty, v_price, v_taxed, v_list, v_reason);
      -- The job's price becomes what was actually charged (a register discount
      -- sticks); the line keeps the job's price before the sale as its list price.
      update string_jobs set paid_sale_id = v_sale_id, price = v_price where id = v_job;

    else
      if not exists (select 1 from gift_cards where id = v_gc) then
        raise exception 'Unknown gift_card_id % in sale line', v_gc;
      end if;
      select coalesce(sum(amount), 0) into v_prev from gift_card_txns where gift_card_id = v_gc;
      insert into sale_lines (sale_id, gift_card_id, qty, unit_price, taxable) values (v_sale_id, v_gc, v_qty, v_price, v_taxed);
      insert into gift_card_txns (gift_card_id, amount, reason, sale_id) values (v_gc, v_line_total, 'load', v_sale_id);
      if v_prev <= 0 then update gift_cards set customer_id = p_customer_id where id = v_gc; end if;
    end if;

    -- Checked after the line's own rules, so a line that can't be sold says why.
    if (v_priced->>'price_changed')::boolean and v_reason is null then
      raise exception 'Price changed from $% on line %: give a reason',
        to_char(v_list, 'FM999999990.00'), v_index + 1;
    end if;
  end loop;

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

  if abs(v_paid - v_total) > 0.005 then
    raise exception 'Payments ($%) must equal the sale total ($%). The total may have changed: go back and check the ticket.',
      to_char(v_paid, 'FM999999990.00'), to_char(v_total, 'FM999999990.00');
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

-- -----------------------------------------------------------------------------
-- 6. sales_summary — same as 0048, plus price changes in the period
-- -----------------------------------------------------------------------------
-- Runs with the caller's permissions (security invoker), as before.
drop function if exists sales_summary(timestamptz, timestamptz);

create function sales_summary(p_from timestamptz, p_to timestamptz)
returns table (
  gross           numeric,
  tax             numeric,
  refunds         numeric,
  net             numeric,
  card            numeric,
  cash            numeric,
  check_amt       numeric,
  store_credit    numeric,
  gift_card       numeric,
  num_customers   integer,
  num_tickets     integer,
  num_items       integer,
  gift_cards_sold numeric,
  price_changes   integer,
  price_change_total numeric
)
language sql
stable
set search_path = public, pg_temp
as $$
  with s as (
    select id, tax, customer_id from sales where sold_at >= p_from and sold_at < p_to
  ),
  lines as (
    select sl.qty, sl.unit_price, sl.product_id, sl.gift_card_id, sl.list_price
    from sale_lines sl join s on s.id = sl.sale_id
  ),
  pay as (select sp.method, sp.amount from sale_payments sp join s on s.id = sp.sale_id),
  r as (select id, subtotal, tax from refunds where refunded_at >= p_from and refunded_at < p_to),
  rpay as (select rp.method, rp.amount from refund_payments rp join r on r.id = rp.refund_id),
  returned_items as (
    select rl.qty
    from refund_lines rl
    join r on r.id = rl.refund_id
    join sale_lines sl on sl.id = rl.sale_line_id
    where sl.product_id is not null
  ),
  totals as (
    select
      coalesce((select sum(qty * unit_price) from lines where gift_card_id is null), 0) as gross,
      coalesce((select sum(qty * unit_price) from lines where gift_card_id is not null), 0) as gift_cards_sold,
      coalesce((select sum(tax) from s), 0)                                              as tax,
      coalesce((select sum(subtotal + tax) from r), 0)                                   as refunds
  )
  select
    t.gross,
    t.tax,
    t.refunds,
    t.gross + t.tax - t.refunds + t.gift_cards_sold                                             as net,
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
    (coalesce((select sum(qty) from lines where product_id is not null), 0)
      - coalesce((select sum(qty) from returned_items), 0))::int                                as num_items,
    t.gift_cards_sold,
    (select count(*) from lines where list_price is not null and unit_price <> list_price)::int  as price_changes,
    coalesce((select sum(qty * (unit_price - list_price)) from lines
               where list_price is not null and unit_price <> list_price), 0)                    as price_change_total
  from totals t;
$$;

-- -----------------------------------------------------------------------------
-- 7. Quick-pick reasons
-- -----------------------------------------------------------------------------
insert into lookup_values (kind, value) values
  ('price_reason', 'Price match'),
  ('price_reason', 'Damaged'),
  ('price_reason', 'Staff')
on conflict (kind, value) do nothing;

revoke all on function sale_totals(jsonb) from public, anon, authenticated;
revoke all on function require_sale_line(jsonb) from public, anon, authenticated;
revoke all on function quote_sale(jsonb, uuid) from public, anon;
revoke all on function record_sale(jsonb, uuid, jsonb, text) from public, anon;
revoke all on function sales_summary(timestamptz, timestamptz) from public, anon;
grant execute on function quote_sale(jsonb, uuid) to authenticated;
grant execute on function record_sale(jsonb, uuid, jsonb, text) to authenticated;
grant execute on function sales_summary(timestamptz, timestamptz) to authenticated;
