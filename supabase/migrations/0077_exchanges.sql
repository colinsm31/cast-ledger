-- =============================================================================
-- 0077_exchanges.sql — return and sell on one ticket (AceStock, Phase 3D)
--
-- Before:
--   • Swapping shoes for another size took a refund and then a separate sale,
--     with the money going out and back in and nothing tying the two.
--
-- Now:
--   1. record_exchange returns items from a sale and sells new ones in one
--      step: either both are saved or neither is. It calls record_refund and
--      record_sale, so every rule of each still applies.
--   2. The returned items' value moves to the new sale as an 'exchange'
--      payment, on the refund and on the sale (no money changes hands for
--      it). The customer pays any difference the usual ways; when the return
--      is worth more, the cashier gives the difference back the usual ways,
--      and the refund-type rules apply to that part only.
--   3. exchanges links the refund and the sale, with the credit moved.
--   4. 'exchange' is a payment type only record_exchange writes; the sales
--      summary leaves it out of the payment-type totals (it nets to zero).
--
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The exchange payment type
-- -----------------------------------------------------------------------------
alter table sale_payments drop constraint if exists sale_payments_method_check;
alter table sale_payments add constraint sale_payments_method_check
  check (method in ('cash', 'credit', 'gift_card', 'store_credit', 'check', 'exchange'));
alter table refund_payments drop constraint if exists refund_payments_method_check;
alter table refund_payments add constraint refund_payments_method_check
  check (method in ('cash', 'credit', 'gift_card', 'store_credit', 'check', 'exchange'));
alter table sales drop constraint if exists sales_payment_method_check;
alter table sales add constraint sales_payment_method_check
  check (payment_method is null or payment_method in ('credit', 'cash', 'gift_card', 'store_credit', 'check', 'split', 'exchange'));

-- -----------------------------------------------------------------------------
-- 2. Exchanges
-- -----------------------------------------------------------------------------
create table if not exists exchanges (
  id          uuid primary key default gen_random_uuid(),
  refund_id   uuid not null unique references refunds (id),
  sale_id     uuid not null unique references sales (id),
  credit      numeric(12, 2) not null check (credit >= 0),
  user_id     uuid default auth.uid() references profiles (id),
  created_at  timestamptz not null default now()
);
comment on table exchanges is 'A return and a sale on one ticket; credit is what moved from the return to the sale';
create index if not exists idx_exchanges_created on exchanges (created_at);

alter table exchanges enable row level security;
drop policy if exists exchanges_staff_select on exchanges;
create policy exchanges_staff_select on exchanges for select to authenticated using (is_staff());
revoke all on exchanges from anon, authenticated;
grant select on exchanges to authenticated;

drop trigger if exists trg_enforce_staff_writer on exchanges;
create trigger trg_enforce_staff_writer before insert or update or delete on exchanges
  for each statement execute function enforce_staff_writer();

-- -----------------------------------------------------------------------------
-- 3. record_sale — same as 0062; an exchange's credit pays first
-- -----------------------------------------------------------------------------
create or replace function record_sale(
  p_lines       jsonb,
  p_customer_id uuid,
  p_payments    jsonb,
  p_note        text,
  p_ticket      jsonb default null,
  p_approval_id uuid default null
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
  v_unit_price  numeric;
  v_line_each   numeric;
  v_ticket_each numeric;
  v_line_disc   numeric;
  v_disc_reason text;
  v_ticket      numeric := nullif(nullif(p_ticket->>'discount', '')::numeric, 0);
  v_problem     text;
  v_approved_by uuid;
  v_exempt_id   text;
  v_credit      numeric;
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
  if p_approval_id is not null then
    perform 1 from discount_approvals where id = p_approval_id for update;
  end if;
  -- Read after the locks above, like everything else this sale checks.
  v_exempt_id := customer_tax_exempt_id(p_customer_id);

  -- The totals, and which lines are taxed, come from sale_totals: the same
  -- function quote_sale uses, so the total the register showed before payment
  -- is the total this sale requires.
  v_totals   := sale_totals(p_lines, p_ticket, v_exempt_id is not null);
  v_subtotal := (v_totals->>'subtotal')::numeric;
  v_tax      := (v_totals->>'tax')::numeric;
  v_rate     := (v_totals->>'tax_rate')::numeric;
  v_total    := (v_totals->>'total')::numeric;

  insert into sales (id, customer_id, subtotal, note, ticket_discount, ticket_discount_reason, tax_exempt_id)
  values (v_sale_id, p_customer_id, 0, nullif(trim(p_note), ''),
          v_ticket, v_totals->>'ticket_discount_reason', v_exempt_id);

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
    v_unit_price  := (v_priced->>'unit_price')::numeric;
    v_line_each   := nullif((v_priced->>'line_discount_each')::numeric, 0);
    v_ticket_each := nullif((v_priced->>'ticket_discount_each')::numeric, 0);
    v_line_disc   := nullif(nullif(v_line->>'discount', '')::numeric, 0);
    v_disc_reason := v_priced->>'discount_reason';

    perform require_sale_line(v_line);

    v_line_total := v_qty * v_unit_price;

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

        insert into sale_lines (sale_id, product_id, product_unit_id, qty, unit_price, taxable, list_price, price_reason,
                              price_before_discount, line_discount, line_discount_each, ticket_discount_each, discount_reason)
        values (v_sale_id, v_product, v_unit, v_qty, v_unit_price, v_taxed, v_list, v_reason,
              case when v_unit_price <> v_price then v_price end, v_line_disc, v_line_each, v_ticket_each, v_disc_reason);
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
        insert into sale_lines (sale_id, product_id, qty, unit_price, taxable, list_price, price_reason,
                              price_before_discount, line_discount, line_discount_each, ticket_discount_each, discount_reason)
        values (v_sale_id, v_product, v_qty, v_unit_price, v_taxed, v_list, v_reason,
              case when v_unit_price <> v_price then v_price end, v_line_disc, v_line_each, v_ticket_each, v_disc_reason);
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
      insert into sale_lines (sale_id, string_job_id, qty, unit_price, taxable, list_price, price_reason,
                              price_before_discount, line_discount, line_discount_each, ticket_discount_each, discount_reason)
      values (v_sale_id, v_job, v_qty, v_unit_price, v_taxed, v_list, v_reason,
              case when v_unit_price <> v_price then v_price end, v_line_disc, v_line_each, v_ticket_each, v_disc_reason);
      -- The job's price becomes what was actually charged (a register discount
      -- sticks); the line keeps the job's price before the sale as its list price.
      update string_jobs set paid_sale_id = v_sale_id, price = v_unit_price where id = v_job;

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

  -- Discounts, checked after each line's own rules: anything over the staff
  -- limit needs an admin (signed in, or their approval, used up by this sale).
  v_problem := discount_approval_problem(v_totals, p_approval_id);
  if v_problem is not null then
    raise exception '%', v_problem;
  end if;
  if (v_totals->>'max_discount_percent')::numeric > (v_totals->>'staff_discount_cap')::numeric then
    if is_admin() then
      v_approved_by := auth.uid();
    else
      select approved_by into v_approved_by from discount_approvals where id = p_approval_id;
      update discount_approvals set sale_id = v_sale_id where id = p_approval_id;
    end if;
    update sales set discount_approved_by = v_approved_by where id = v_sale_id;
  end if;

  -- In an exchange (record_exchange, 0077) the returned items' credit pays
  -- first, as an 'exchange' payment; the payments cover the rest.
  v_credit := nullif(current_setting('acestock.exchange_credit', true), '')::numeric;
  if v_credit is not null and v_credit > 0 then
    if v_credit > v_total + 0.005 then
      raise exception 'The return ($%) is more than the new items ($%): give the difference back on the return',
        to_char(v_credit, 'FM999999990.00'), to_char(v_total, 'FM999999990.00');
    end if;
    insert into sale_payments (sale_id, method, amount) values (v_sale_id, 'exchange', v_credit);
    v_paid := v_credit;
  end if;

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


revoke all on function record_sale(jsonb, uuid, jsonb, text, jsonb, uuid) from public, anon;
grant execute on function record_sale(jsonb, uuid, jsonb, text, jsonb, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 4. record_refund — same as 0075; in an exchange what isn't given back is credit
-- -----------------------------------------------------------------------------
create or replace function record_refund(
  p_sale_id              uuid,
  p_lines                jsonb,
  p_payments             jsonb,
  p_reason               text,
  p_note                 text,
  p_method_change_reason text default null,
  p_approval_id          uuid default null
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
  v_job         string_jobs%rowtype;
  v_price       numeric;
  v_taxable     numeric := 0;
  v_load_cards  uuid[] := '{}';
  v_card_left   numeric;
  v_ok          boolean;
  v_approver    uuid;
  v_rest        numeric;
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
    if v_sl.product_id is null and v_sl.string_job_id is null and v_sl.gift_card_id is null then
      raise exception 'Only product, stringing and gift card lines can be returned';
    end if;
    if v_sl.gift_card_id is not null and v_qty <> v_sl.qty then
      raise exception 'A gift card load is refunded whole';
    end if;
    if v_sl.string_job_id is not null and v_qty <> 1 then
      raise exception 'A stringing charge is refunded whole (qty 1)';
    end if;
    if v_sl.product_unit_id is not null and v_qty <> 1 then
      raise exception 'A racquet frame is returned one at a time (qty 1)';
    end if;

    select coalesce(sum(rl.qty), 0) into v_returned from refund_lines rl where rl.sale_line_id = v_sl_id and rl.kind = 'return';
    if v_qty > v_sl.qty - v_returned then
      raise exception 'Cannot return % of line (only % remaining)', v_qty, v_sl.qty - v_returned;
    end if;

    -- A stringing charge gives back what's left of it: its price less any
    -- string-change give-backs already made against it (0043).
    v_price := v_sl.unit_price;
    if v_sl.string_job_id is not null then
      v_price := v_price - coalesce((select sum(rl.qty * rl.unit_price) from refund_lines rl
                                      where rl.sale_line_id = v_sl_id and rl.kind = 'string_change'), 0);
      if v_price <= 0 then
        raise exception 'Nothing is left to refund on this stringing charge: string changes already gave it back';
      end if;
    end if;

    insert into refund_lines (refund_id, sale_line_id, qty, unit_price)
    values (v_refund_id, v_sl_id, v_qty, v_price);

    if v_sl.gift_card_id is not null then
      -- Only a load the card still holds in full comes back off it.
      perform 1 from gift_cards where id = v_sl.gift_card_id for update;
      select coalesce(sum(amount), 0) into v_card_left from gift_card_txns where gift_card_id = v_sl.gift_card_id;
      if v_card_left < v_qty * v_price then
        raise exception 'Gift card % has $% left of this $% load: only an unused load can be refunded',
          (select code from gift_cards where id = v_sl.gift_card_id), to_char(v_card_left, 'FM999999990.00'),
          to_char(v_qty * v_price, 'FM999999990.00');
      end if;
      insert into gift_card_txns (gift_card_id, amount, reason, sale_id)
      values (v_sl.gift_card_id, -(v_qty * v_price), 'load refund', p_sale_id);
      if v_card_left - v_qty * v_price <= 0 then
        update gift_cards set customer_id = null where id = v_sl.gift_card_id;
      end if;
      v_load_cards := v_load_cards || v_sl.gift_card_id;
    elsif v_sl.string_job_id is not null then
      -- The job stays on record, marked refunded. One not started yet is
      -- cancelled; one strung and waiting is delivered first.
      select * into v_job from string_jobs where id = v_sl.string_job_id for update;
      if v_job.status = 'complete' then
        raise exception 'String job J% is strung and waiting: deliver it before refunding its charge', v_job.job_number;
      end if;
      if v_job.status = 'entered' then
        update string_jobs
           set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
         where id = v_job.id;
      end if;
      if v_job.refund_id is null then
        update string_jobs set refunded_at = now(), refund_id = v_refund_id where id = v_job.id;
      end if;
    elsif v_sl.product_unit_id is null then
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

    v_sub := v_sub + v_qty * v_price;
    if v_sl.taxable then
      v_taxable := v_taxable + v_qty * v_price;
    end if;
  end loop;

  -- A gift card load comes back only with an admin: signed in here, or their
  -- one-time approval (used up by this refund).
  if cardinality(v_load_cards) > 0 and not is_admin() then
    if p_approval_id is null then
      raise exception 'Refunding a gift card load needs an admin''s approval';
    end if;
    select a.refund_id is null and a.expires_at > now(), a.approved_by into v_ok, v_approver
      from refund_approvals a where a.id = p_approval_id
      for update;
    if not coalesce(v_ok, false) then
      raise exception 'The admin approval has expired or been used: ask again';
    end if;
    update refund_approvals set refund_id = v_refund_id where id = p_approval_id;
    update refunds set approved_by = v_approver where id = v_refund_id;
  elsif cardinality(v_load_cards) > 0 then
    update refunds set approved_by = auth.uid() where id = v_refund_id;
  end if;

  -- Tax on everything taxable refunded so far (rounded once), minus tax
  -- already refunded, never beyond what the sale charged. Only lines the sale
  -- taxed count (stringing may be untaxed).
  v_tax   := sale_refund_tax(p_sale_id, v_taxable, v_refund_id);
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
        if v_gc = any (v_load_cards) then
          raise exception 'A refunded load can''t go back onto the same gift card';
        end if;
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

  -- In an exchange (record_exchange, 0077) what isn't given back goes toward
  -- the new items, as an 'exchange' refund payment.
  if coalesce(current_setting('acestock.exchange_id', true), '') <> '' then
    v_rest := v_total - v_paid;
    if v_rest < -0.005 then
      raise exception 'The money back ($%) is more than the return ($%)',
        to_char(v_paid, 'FM999999990.00'), to_char(v_total, 'FM999999990.00');
    end if;
    if v_rest > 0.005 then
      insert into refund_payments (refund_id, method, amount) values (v_refund_id, 'exchange', v_rest);
      v_paid := v_paid + v_rest;
    end if;
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


revoke all on function record_refund(uuid, jsonb, jsonb, text, text, text, uuid) from public, anon;
grant execute on function record_refund(uuid, jsonb, jsonb, text, text, text, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 5. record_exchange
-- -----------------------------------------------------------------------------
-- p_return_lines and p_refund_payments are as for record_refund (the money
-- given back when the return is worth more; empty otherwise); p_new_lines,
-- p_payments, p_ticket and p_approval_id as for record_sale (the payments
-- cover what the credit doesn't).
create or replace function record_exchange(
  p_sale_id              uuid,
  p_return_lines         jsonb,
  p_new_lines            jsonb,
  p_customer_id          uuid,
  p_payments             jsonb,
  p_refund_payments      jsonb,
  p_reason               text,
  p_ticket               jsonb default null,
  p_approval_id          uuid default null,
  p_method_change_reason text default null,
  p_refund_approval_id   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_exchange_id uuid := gen_random_uuid();
  v_refund_id   uuid;
  v_sale_id     uuid;
  v_credit      numeric;
begin
  perform require_staff();

  perform set_config('acestock.exchange_id', v_exchange_id::text, true);
  v_refund_id := record_refund(p_sale_id, p_return_lines, coalesce(p_refund_payments, '[]'::jsonb),
                               coalesce(nullif(btrim(p_reason), ''), 'Exchange'), null,
                               p_method_change_reason, p_refund_approval_id);
  perform set_config('acestock.exchange_id', '', true);

  select coalesce(sum(amount), 0) into v_credit
    from refund_payments where refund_id = v_refund_id and method = 'exchange';

  perform set_config('acestock.exchange_credit', v_credit::text, true);
  v_sale_id := record_sale(p_new_lines, p_customer_id, coalesce(p_payments, '[]'::jsonb), 'Exchange',
                           p_ticket, p_approval_id);
  perform set_config('acestock.exchange_credit', '', true);

  insert into exchanges (id, refund_id, sale_id, credit) values (v_exchange_id, v_refund_id, v_sale_id, v_credit);

  return jsonb_build_object('exchange_id', v_exchange_id, 'refund_id', v_refund_id, 'sale_id', v_sale_id,
                            'credit', v_credit);
end;
$$;

revoke all on function record_exchange(uuid, jsonb, jsonb, uuid, jsonb, jsonb, text, jsonb, uuid, text, uuid) from public, anon;
grant execute on function record_exchange(uuid, jsonb, jsonb, uuid, jsonb, jsonb, text, jsonb, uuid, text, uuid) to authenticated;
