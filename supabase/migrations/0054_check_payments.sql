-- =============================================================================
-- 0054_check_payments.sql — checks as a payment type (AceStock, Phase 2A)
--
-- Before:
--   • "check" was refused as a payment or refund type everywhere, though the
--     sales report already had a "paid by check" row (always $0).
--
-- Now:
--   1. settings.accept_checks (off by default) turns checks on.
--   2. sale_payments and refund_payments gain check_number. A check payment
--      or refund always has one: digits only, up to 10.
--   3. 'check' is allowed as a payment and refund type in the tables, and as
--      the sale's payment summary.
--   4. require_check_number(text): the check number rule. Internal.
--   5. record_sale (carried over from 0053) takes a check while the shop
--      takes checks. Payments must still add up to the total exactly, so a
--      check is never for more than is owed.
--   6. record_refund (carried over from 0046) refunds by check while the shop
--      takes checks, or when the sale itself was paid by check. Refunding a
--      check sale as cash or store credit is a payment-type change, so it
--      needs a reason, as for any other type.
--   7. sale_refundable_by_method (carried over from 0043) counts checks.
--   8. sales_summary (carried over from 0053) reports checks taken minus
--      checks refunded; its return type is unchanged.
--
-- Turning checks off later leaves past check sales and the report as they
-- are; only new check payments are refused. String changes are still paid
-- in cash, credit or store credit. Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1–3. Settings and columns
-- -----------------------------------------------------------------------------
alter table settings add column if not exists accept_checks boolean not null default false;

alter table sale_payments add column if not exists check_number text;
alter table refund_payments add column if not exists check_number text;

alter table sale_payments drop constraint if exists sale_payments_method_check;
alter table sale_payments add constraint sale_payments_method_check
  check (method in ('cash', 'credit', 'gift_card', 'store_credit', 'check'));
alter table refund_payments drop constraint if exists refund_payments_method_check;
alter table refund_payments add constraint refund_payments_method_check
  check (method in ('cash', 'credit', 'gift_card', 'store_credit', 'check'));
alter table sales drop constraint if exists sales_payment_method_check;
alter table sales add constraint sales_payment_method_check
  check (payment_method is null or payment_method in ('credit', 'cash', 'gift_card', 'store_credit', 'check', 'split'));

alter table sale_payments drop constraint if exists ck_sale_payments_check_number_format;
alter table sale_payments add constraint ck_sale_payments_check_number_format
  check ((method = 'check') = (check_number is not null) and (check_number is null or check_number ~ '^[0-9]{1,10}$'));
alter table refund_payments drop constraint if exists ck_refund_payments_check_number_format;
alter table refund_payments add constraint ck_refund_payments_check_number_format
  check ((method = 'check') = (check_number is not null) and (check_number is null or check_number ~ '^[0-9]{1,10}$'));

comment on column settings.accept_checks is 'Checks are offered at payment and refund';
comment on column sale_payments.check_number is 'Set for check payments only';
comment on column refund_payments.check_number is 'The refund check''s number; set for check refunds only';

-- -----------------------------------------------------------------------------
-- 4. require_check_number — the trimmed number, or an error
-- -----------------------------------------------------------------------------
create or replace function require_check_number(p_number text)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_number text := trim(p_number);
begin
  if v_number is null or v_number !~ '^[0-9]{1,10}$' then
    raise exception 'A check needs its check number (digits only, up to 10)';
  end if;
  return v_number;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. record_sale — same as 0053, and it takes checks
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
  v_checks      boolean := false;
  v_check_no    text;
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

  select block_oversell, accept_checks into v_block, v_checks from settings where id = true;

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
      if v_method not in ('cash', 'credit', 'gift_card', 'store_credit', 'check') then raise exception 'Invalid payment method "%"', v_method; end if;

      if v_method = 'gift_card' then
        if v_gc is null then raise exception 'Gift card payment needs a gift_card_id'; end if;
        select coalesce(sum(amount), 0) into v_bal from gift_card_txns where gift_card_id = v_gc;
        if v_bal < v_amount then raise exception 'Gift card balance % is less than %', v_bal, v_amount; end if;
        insert into gift_card_txns (gift_card_id, amount, reason, sale_id) values (v_gc, -v_amount, 'redeem', v_sale_id);
        insert into sale_payments (sale_id, method, amount, gift_card_id) values (v_sale_id, 'gift_card', v_amount, v_gc);
        select coalesce(sum(amount), 0) into v_bal from gift_card_txns where gift_card_id = v_gc;
        if v_bal <= 0 then update gift_cards set customer_id = null where id = v_gc; end if;
      elsif v_method = 'check' then
        if not coalesce(v_checks, false) then
          raise exception 'This shop doesn''t take checks: turn them on in Settings first';
        end if;
        v_check_no := require_check_number(v_pay->>'check_number');
        insert into sale_payments (sale_id, method, amount, check_number) values (v_sale_id, 'check', v_amount, v_check_no);
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
-- 6. record_refund — same as 0046, and it refunds by check
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
    if v_sl.product_unit_id is not null then
      raise exception 'Returning individual (serialized) items is not supported yet';
    end if;

    select coalesce(sum(rl.qty), 0) into v_returned from refund_lines rl where rl.sale_line_id = v_sl_id and rl.kind = 'return';
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

-- -----------------------------------------------------------------------------
-- 7. sale_refundable_by_method — same as 0043, plus checks
-- -----------------------------------------------------------------------------
-- What each payment type can still give back from a sale: what the sale took
-- that way, net of refunds other than p_refund_id.
create or replace function sale_refundable_by_method(p_sale_id uuid, p_refund_id uuid)
returns table (method text, refundable numeric)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.method,
         greatest(
           coalesce((select sum(sp.amount) from sale_payments sp
                      where sp.sale_id = p_sale_id and sp.method = m.method), 0)
         - coalesce((select sum(rp.amount) from refund_payments rp join refunds r on r.id = rp.refund_id
                      where r.sale_id = p_sale_id and r.id is distinct from p_refund_id and rp.method = m.method), 0),
           0)
    from (values ('cash'), ('credit'), ('gift_card'), ('store_credit'), ('check')) as m(method);
$$;

-- -----------------------------------------------------------------------------
-- 8. sales_summary — same as 0053, with checks counted
-- -----------------------------------------------------------------------------
create or replace function sales_summary(p_from timestamptz, p_to timestamptz)
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
    coalesce((select sum(amount) from pay where method = 'check'), 0)
      - coalesce((select sum(amount) from rpay where method = 'check'), 0)                      as check_amt,
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

revoke all on function require_check_number(text) from public, anon, authenticated;
revoke all on function sale_refundable_by_method(uuid, uuid) from public, anon, authenticated;
revoke all on function record_sale(jsonb, uuid, jsonb, text) from public, anon;
revoke all on function record_refund(uuid, jsonb, jsonb, text, text, text) from public, anon;
revoke all on function sales_summary(timestamptz, timestamptz) from public, anon;
grant execute on function record_sale(jsonb, uuid, jsonb, text) to authenticated;
grant execute on function record_refund(uuid, jsonb, jsonb, text, text, text) to authenticated;
grant execute on function sales_summary(timestamptz, timestamptz) to authenticated;
