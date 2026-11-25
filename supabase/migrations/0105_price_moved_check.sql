-- =============================================================================
-- 0105_price_moved_check.sql — a catalog price that moves during checkout (AceStock, Phase 4A review)
--
-- Before 0093, record_sale refused a line whose price differed from the
-- catalog without a reason. That also caught a catalog price changing while
-- the cashier was on the payment screen. Since 0093 the old price is quietly
-- saved as a price change nobody made.
--
-- Now each line may carry list_price: the list price the register showed (from
-- quote_sale). If it's given and the catalog's price is different now,
-- record_sale refuses the sale ("A price changed in the catalog while this
-- ticket was open"), and the register goes back to the ticket with the new
-- price. Lines without list_price (older screens, exchanges) work as before.
-- No reason is ever asked for. Otherwise as record_sale 0093.
--
-- Re-runnable.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.record_sale(p_lines jsonb, p_customer_id uuid, p_payments jsonb, p_note text, p_ticket jsonb DEFAULT NULL::jsonb, p_approval_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    -- The register sends the list price it showed (0105). If the catalog
    -- price has moved since, a different price would be saved as a price
    -- change nobody made: refuse, so the register shows the new price.
    if (v_line->>'list_price') is not null
       and (v_line->>'list_price')::numeric is distinct from v_list then
      raise exception 'A price changed in the catalog while this ticket was open: check the ticket and take payment again'
        using errcode = 'P0001', hint = 'price_moved';
    end if;
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
$function$;

revoke all on function record_sale(p_lines jsonb, p_customer_id uuid, p_payments jsonb, p_note text, p_ticket jsonb, p_approval_id uuid) from public, anon;
grant execute on function record_sale(p_lines jsonb, p_customer_id uuid, p_payments jsonb, p_note text, p_ticket jsonb, p_approval_id uuid) to authenticated;
