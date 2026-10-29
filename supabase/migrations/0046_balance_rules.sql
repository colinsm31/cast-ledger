-- =============================================================================
-- 0046_balance_rules.sql — gift card and store credit value, gift card refunds,
--                          customer deletes and whole cents
--                          (AceStock, foundation code review #5, #6, #7, #9)
--
-- Before:
--   • Staff could add value to a gift card (adjust_gift_card) or add store
--     credit (add_store_credit) with no reason (#5).
--   • The refund payment-type check compared by type only, so a sale paid
--     with gift card A could be refunded to card B with no reason (#6).
--   • Deleting a customer deleted their store credit history with them, and
--     any staff member could delete a customer through the API (#7).
--   • Amounts with fractions of a cent were accepted: the totals were checked
--     on the raw amounts, then each one was rounded when stored, so three
--     payments of 3.334 + 3.333 + 3.333 settled a $10.00 sale as $9.99 (#9).
--
-- Now:
--   1. Adding value to a gift card, and adding store credit by hand, need a
--      reason. Taking value off a gift card doesn't.
--   2. A refund to a gift card is limited to what that card paid on the sale
--      (net of earlier refunds to it); beyond that it's a payment-type change
--      and needs a reason, as for any other payment type.
--   3. Store credit history blocks deleting its customer. Only admins delete
--      customers, and only customers with no history.
--   4. Every money amount passed to a server function has whole cents.
--
-- Re-runnable.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- 4. Whole cents. Two internal helpers, called first by each function that
--    takes money: one amount, or one field of each element of a JSON array.
-- ----------------------------------------------------------------------------
create or replace function require_cents(p_amount numeric, p_label text)
returns void
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  if p_amount is not null and p_amount <> round(p_amount, 2) then
    raise exception '% % has more than 2 decimal places', p_label, trim_scale(p_amount);
  end if;
end;
$$;

create or replace function require_cents_each(p_items jsonb, p_key text, p_label text)
returns void
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_item jsonb;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return;
  end if;
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    perform require_cents((v_item->>p_key)::numeric, p_label);
  end loop;
end;
$$;

revoke all on function require_cents(numeric, text) from public, anon, authenticated;
revoke all on function require_cents_each(jsonb, text, text) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 1. Gift card adjustments and manual store credit.
-- ----------------------------------------------------------------------------
-- adjust_gift_card — same as 0038 (owner rights per 0040), plus: whole cents,
-- and adding value needs a reason (taking it off still defaults to 'adjust').
create or replace function adjust_gift_card(p_gift_card_id uuid, p_amount numeric, p_reason text)
returns numeric
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_bal numeric;
begin
  if p_amount is null or p_amount = 0 then
    raise exception 'Adjustment amount must be non-zero';
  end if;
  perform require_cents(p_amount, 'Adjustment');
  if p_amount > 0 and coalesce(trim(p_reason), '') = '' then
    raise exception 'A reason is required to add value to a gift card';
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

-- add_store_credit — same as 0024 (owner rights per 0040), plus: whole cents
-- and a reason.
create or replace function add_store_credit(p_customer_id uuid, p_amount numeric, p_reason text)
returns numeric
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'Store credit amount must be positive';
  end if;
  perform require_cents(p_amount, 'Store credit amount');
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'A reason is required to add store credit';
  end if;
  if not exists (select 1 from customers where id = p_customer_id) then
    raise exception 'Unknown customer %', p_customer_id;
  end if;
  insert into store_credit_txns (customer_id, amount, reason)
  values (p_customer_id, p_amount, trim(p_reason));
  return (select coalesce(sum(amount), 0) from store_credit_txns where customer_id = p_customer_id);
end;
$$;

revoke all on function adjust_gift_card(uuid, numeric, text) from public, anon;
revoke all on function add_store_credit(uuid, numeric, text) from public, anon;
grant execute on function adjust_gift_card(uuid, numeric, text) to authenticated;
grant execute on function add_store_credit(uuid, numeric, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 2. Gift card refunds go back to the card that paid.
-- ----------------------------------------------------------------------------
-- refund_method_overages — same as 0043 (staff-only per 0044), plus: gift
-- cards are checked card by card, and named by their code. Used by
-- record_refund and change_paid_string_job (which can't give back to a card).
create or replace function refund_method_overages(p_sale_id uuid, p_refund_id uuid)
returns text[]
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(x.label order by x.label), '{}')
    from (
      select b.method as label
        from sale_refundable_by_method(p_sale_id, p_refund_id) b
       where b.method <> 'gift_card'
         and (select coalesce(sum(rp.amount), 0) from refund_payments rp
               where rp.refund_id = p_refund_id and rp.method = b.method) > b.refundable + 0.005
      union all
      select 'gift card ' || g.code
        from (select rp.gift_card_id, sum(rp.amount) as sent
                from refund_payments rp
               where rp.refund_id = p_refund_id and rp.method = 'gift_card'
               group by rp.gift_card_id) c
        join gift_cards g on g.id = c.gift_card_id
       where c.sent > greatest(
               coalesce((select sum(sp.amount) from sale_payments sp
                          where sp.sale_id = p_sale_id and sp.method = 'gift_card'
                            and sp.gift_card_id = c.gift_card_id), 0)
             - coalesce((select sum(rp.amount) from refund_payments rp join refunds r on r.id = rp.refund_id
                          where r.sale_id = p_sale_id and r.id is distinct from p_refund_id
                            and rp.method = 'gift_card' and rp.gift_card_id = c.gift_card_id), 0),
               0) + 0.005
    ) x;
$$;

revoke all on function refund_method_overages(uuid, uuid) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. Customers: history blocks a delete; only admins delete.
-- ----------------------------------------------------------------------------
alter table store_credit_txns drop constraint if exists store_credit_txns_customer_id_fkey;
alter table store_credit_txns
  add constraint store_credit_txns_customer_id_fkey
  foreign key (customer_id) references customers (id) on delete restrict;

-- Says what history a customer has, instead of a foreign-key error. Racquets
-- with no string jobs still go with the customer.
create or replace function guard_customer_delete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_history text[];
begin
  select array_remove(array[
           case when exists (select 1 from sales where customer_id = old.id) then 'sales' end,
           case when exists (select 1 from store_credit_txns where customer_id = old.id) then 'store credit' end,
           case when exists (select 1 from gift_cards where customer_id = old.id) then 'gift cards' end,
           case when exists (select 1 from product_units where customer_id = old.id) then 'racquet units' end,
           case when exists (select 1 from string_jobs j join customer_rackets r on r.id = j.customer_racket_id
                              where r.customer_id = old.id) then 'string jobs' end
         ], null)
    into v_history;
  if cardinality(v_history) > 0 then
    raise exception '% % has % history, so they can''t be deleted',
      old.first_name, old.last_name, array_to_string(v_history, ', ');
  end if;
  return old;
end;
$$;

revoke all on function guard_customer_delete() from public, anon, authenticated;

drop trigger if exists trg_guard_customer_delete on customers;
create trigger trg_guard_customer_delete
  before delete on customers
  for each row execute function guard_customer_delete();

drop policy if exists customers_authenticated_all on customers;
drop policy if exists customers_staff_select on customers;
drop policy if exists customers_staff_insert on customers;
drop policy if exists customers_staff_update on customers;
drop policy if exists customers_admin_delete on customers;
create policy customers_staff_select on customers for select to authenticated using (is_staff());
create policy customers_staff_insert on customers for insert to authenticated with check (is_staff());
create policy customers_staff_update on customers for update to authenticated using (is_staff()) with check (is_staff());
create policy customers_admin_delete on customers for delete to authenticated using (is_admin());

-- ----------------------------------------------------------------------------
-- 4 (continued). The functions that take money, each the same as its latest
-- version plus a whole-cents check at the start:
--   record_sale, record_refund, change_paid_string_job — 0043
--   receive_stock                                      — 0045
-- ----------------------------------------------------------------------------

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
  perform require_cents_each(p_lines, 'unit_price', 'Price');
  perform require_cents_each(p_payments, 'amount', 'Payment amount');
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

        insert into sale_lines (sale_id, product_id, product_unit_id, qty, unit_price, taxable)
        values (v_sale_id, v_product, v_unit, v_qty, v_price, true);
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
        insert into sale_lines (sale_id, product_id, qty, unit_price, taxable) values (v_sale_id, v_product, v_qty, v_price, true);
        insert into inventory_txns (txn_type, product_id, qty, sale_id) values ('sell', v_product, -v_qty, v_sale_id);
      end if;
      v_taxable := v_taxable + v_line_total;

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
      insert into sale_lines (sale_id, string_job_id, qty, unit_price, taxable)
      values (v_sale_id, v_job, v_qty, v_price, v_tax_string);
      -- The job's price becomes what was actually charged (a register discount sticks).
      update string_jobs set paid_sale_id = v_sale_id, price = v_price where id = v_job;
      if v_tax_string then v_taxable := v_taxable + v_line_total; end if;

    else
      if not exists (select 1 from gift_cards where id = v_gc) then
        raise exception 'Unknown gift_card_id % in sale line', v_gc;
      end if;
      select coalesce(sum(amount), 0) into v_prev from gift_card_txns where gift_card_id = v_gc;
      insert into sale_lines (sale_id, gift_card_id, qty, unit_price, taxable) values (v_sale_id, v_gc, v_qty, v_price, false);
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

create or replace function change_paid_string_job(
  p_job_id           uuid,
  p_main_product_id  uuid,
  p_cross_product_id uuid,
  p_main_tension     numeric,
  p_cross_tension    numeric,
  p_payments         jsonb,
  p_reason           text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_quote      jsonb;
  v_direction  text;
  v_amount     numeric;
  v_tax        numeric;
  v_total      numeric;
  v_customer   uuid;
  v_pay        jsonb;
  v_methods    text[] := '{}';
  v_amounts    numeric[] := '{}';
  v_paid       numeric := 0;
  v_i          integer;
  v_sale_id    uuid;
  v_rate       numeric;
  v_taxable    boolean;
  v_count      integer;
  v_balance    numeric;
  v_alloc      jsonb;
  v_refund_id  uuid;
  v_refund_ids uuid[] := '{}';
  v_sale_cust  uuid;
  v_need       numeric;
  v_take       numeric;
  v_changed    text[];
begin
  perform require_cents_each(p_payments, 'amount', 'Payment amount');
  perform require_staff();

  -- Lock the job, then the sales that paid for it (refunds of a sale run one
  -- at a time), so the quote below can't be raced.
  perform 1 from string_jobs where id = p_job_id for update;
  if not found then
    raise exception 'Unknown string job %', p_job_id;
  end if;
  perform 1 from sales
   where id in (select sale_id from sale_lines where string_job_id = p_job_id)
   order by id for update;

  v_quote     := string_change_quote(p_job_id, p_main_product_id, p_cross_product_id);
  v_direction := v_quote->>'direction';
  v_amount    := (v_quote->>'amount')::numeric;
  v_tax       := (v_quote->>'tax')::numeric;
  v_total     := (v_quote->>'total')::numeric;
  v_customer  := (v_quote->>'customer_id')::uuid;

  -- Payments: cash, credit and/or store credit, adding up to the total.
  for v_pay in select * from jsonb_array_elements(coalesce(p_payments, '[]'::jsonb))
  loop
    if (v_pay->>'amount')::numeric is null or (v_pay->>'amount')::numeric <= 0 then
      raise exception 'Payment amount must be positive';
    end if;
    if (v_pay->>'method') is null or (v_pay->>'method') not in ('cash', 'credit', 'store_credit') then
      raise exception 'A string change is paid or given back as cash, credit or store credit';
    end if;
    v_methods := v_methods || (v_pay->>'method');
    v_amounts := v_amounts || (v_pay->>'amount')::numeric;
    v_paid := v_paid + (v_pay->>'amount')::numeric;
  end loop;
  if abs(v_paid - v_total) > 0.005 then
    raise exception 'Payments (%) must equal the string change total (%)', v_paid, v_total;
  end if;
  if 'store_credit' = any (v_methods) and v_customer is null then
    raise exception 'Store credit needs a customer';
  end if;

  -- Change the strings. The entry rules apply (catalog strings, tensions,
  -- availability); the flag lets this paid job's price move by the difference.
  perform set_config('acestock.string_change_job', p_job_id::text, true);
  update string_jobs
     set main_product_id  = p_main_product_id,
         cross_product_id = p_cross_product_id,
         main_tension     = p_main_tension,
         cross_tension    = p_cross_tension,
         price = coalesce(price, 0) + case v_direction when 'charge' then v_amount
                                                       when 'give_back' then -v_amount
                                                       else 0 end
   where id = p_job_id;
  perform set_config('acestock.string_change_job', '', true);

  if v_direction = 'charge' then
    if 'store_credit' = any (v_methods) then
      perform 1 from customers where id = v_customer for update;
      select coalesce(sum(amount), 0) into v_balance from store_credit_txns where customer_id = v_customer;
      if v_balance < (select coalesce(sum(a), 0) from unnest(v_amounts, v_methods) as u(a, m) where m = 'store_credit') then
        raise exception 'Store credit balance % is less than the store credit used', v_balance;
      end if;
    end if;

    select coalesce(tax_rate, 0), coalesce(tax_stringing, false) into v_rate, v_taxable from settings where id;
    v_sale_id := gen_random_uuid();
    insert into sales (id, customer_id, subtotal, tax, tax_rate, note)
    values (v_sale_id, v_customer, v_amount, v_tax, v_rate, 'String change');
    insert into sale_lines (sale_id, string_job_id, qty, unit_price, kind, taxable)
    values (v_sale_id, p_job_id, 1, v_amount, 'string_change', v_taxable);

    for v_i in 1 .. coalesce(array_length(v_methods, 1), 0)
    loop
      insert into sale_payments (sale_id, method, amount) values (v_sale_id, v_methods[v_i], v_amounts[v_i]);
      if v_methods[v_i] = 'store_credit' then
        insert into store_credit_txns (customer_id, amount, reason, sale_id)
        values (v_customer, -v_amounts[v_i], 'redeem', v_sale_id);
      end if;
    end loop;

    select count(*) into v_count from sale_payments where sale_id = v_sale_id;
    update sales
       set payment_method = case when v_count = 1
                                 then (select method from sale_payments where sale_id = v_sale_id limit 1)
                                 else 'split' end
     where id = v_sale_id;

    return jsonb_build_object('direction', 'charge', 'amount', v_amount, 'tax', v_tax, 'total', v_total,
                              'sale_id', v_sale_id);
  end if;

  if v_direction = 'give_back' then
    -- One refund per paying sale (newest first); the payments are spread over
    -- them in the order given.
    v_i := 1;
    for v_alloc in select * from jsonb_array_elements(v_quote->'allocations')
    loop
      v_refund_id := gen_random_uuid();
      select customer_id into v_sale_cust from sales where id = (v_alloc->>'sale_id')::uuid;
      insert into refunds (id, sale_id, subtotal, tax, reason)
      values (v_refund_id, (v_alloc->>'sale_id')::uuid, (v_alloc->>'amount')::numeric, (v_alloc->>'tax')::numeric,
              'String change');
      insert into refund_lines (refund_id, sale_line_id, qty, unit_price, kind)
      values (v_refund_id, (v_alloc->>'sale_line_id')::uuid, 1, (v_alloc->>'amount')::numeric, 'string_change');

      v_need := (v_alloc->>'amount')::numeric + (v_alloc->>'tax')::numeric;
      while v_need > 0.005 and v_i <= array_length(v_methods, 1)
      loop
        v_take := least(v_need, v_amounts[v_i]);
        insert into refund_payments (refund_id, method, amount) values (v_refund_id, v_methods[v_i], v_take);
        if v_methods[v_i] = 'store_credit' then
          insert into store_credit_txns (customer_id, amount, reason, sale_id)
          values (coalesce(v_sale_cust, v_customer), v_take, 'refund', (v_alloc->>'sale_id')::uuid);
        end if;
        v_need := v_need - v_take;
        v_amounts[v_i] := v_amounts[v_i] - v_take;
        if v_amounts[v_i] <= 0.005 then
          v_i := v_i + 1;
        end if;
      end loop;

      v_changed := refund_method_overages((v_alloc->>'sale_id')::uuid, v_refund_id);
      if cardinality(v_changed) > 0 then
        if coalesce(trim(p_reason), '') = '' then
          raise exception 'Giving back more as % than the sale took that way is a payment-type change; give a reason',
            array_to_string(v_changed, ', ');
        end if;
        update refunds set method_change_reason = trim(p_reason) where id = v_refund_id;
      end if;
      v_refund_ids := v_refund_ids || v_refund_id;
    end loop;

    return jsonb_build_object('direction', 'give_back', 'amount', v_amount, 'tax', v_tax, 'total', v_total,
                              'refund_ids', to_jsonb(v_refund_ids));
  end if;

  return jsonb_build_object('direction', 'none', 'amount', 0, 'tax', 0, 'total', 0);
end;
$$;

create or replace function receive_stock(
  p_product_id uuid,
  p_qty        numeric,
  p_unit_cost  numeric,
  p_location   text,
  p_note       text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id         uuid := gen_random_uuid();
  v_serialized boolean;
  v_name       text;
begin
  perform require_cents(p_unit_cost, 'Unit cost');
  if p_qty is null or p_qty <= 0 then
    raise exception 'Receive quantity must be positive';
  end if;
  select is_serialized, trim(coalesce(brand || ' ', '') || name) into v_serialized, v_name
    from products where id = p_product_id;
  if not found then
    raise exception 'Unknown product_id %', p_product_id;
  end if;
  if v_serialized then
    raise exception '% is tracked by unit; receive each one with its own barcode', v_name;
  end if;
  insert into inventory_txns (id, txn_type, product_id, qty, unit_cost, location, note)
  values (v_id, 'receive', p_product_id, p_qty, p_unit_cost, nullif(trim(p_location),''), nullif(trim(p_note),''));
  return v_id;
end;
$$;
revoke all on function record_sale(jsonb, uuid, jsonb, text) from public, anon;
revoke all on function record_refund(uuid, jsonb, jsonb, text, text, text) from public, anon;
revoke all on function change_paid_string_job(uuid, uuid, uuid, numeric, numeric, jsonb, text) from public, anon;
revoke all on function receive_stock(uuid, numeric, numeric, text, text) from public, anon;
grant execute on function record_sale(jsonb, uuid, jsonb, text) to authenticated;
grant execute on function record_refund(uuid, jsonb, jsonb, text, text, text) to authenticated;
grant execute on function change_paid_string_job(uuid, uuid, uuid, numeric, numeric, jsonb, text) to authenticated;
grant execute on function receive_stock(uuid, numeric, numeric, text, text) to authenticated;
