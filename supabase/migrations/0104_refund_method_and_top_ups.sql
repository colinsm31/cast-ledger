-- =============================================================================
-- 0104_refund_method_and_top_ups.sql — two checks 0093 took away (AceStock, Phase 4A review)
--
-- 0093 stopped asking for a reason in several places. The code review found
-- two of those checks did more than ask for a reason:
--   1. A refund paid back a different way than the sale (a card sale refunded
--      in cash) left no trace when no reason was typed. Now refunds keep
--      method_changed_to — the payment types it sent more to than the sale
--      took that way — whether or not a reason was typed. record_refund (and
--      so record_exchange) and change_paid_string_job set it; refunds before
--      now don't have it. report_price_changes lists these refunds as
--      'payment_type_change' rows (no amount; who, when, the reason or
--      "(none)").
--   2. Anyone on staff could add gift card value or store credit. Now adding
--      value (adjust_gift_card with a positive amount, add_store_credit) is
--      for admins; staff can still take value off a gift card, and refunds,
--      sales and exchanges are unchanged. Still no reason needed.
-- Each function is otherwise as its latest version (record_refund,
-- change_paid_string_job, adjust_gift_card, add_store_credit 0093;
-- report_price_changes 0096).
--
-- Re-runnable.
-- =============================================================================

-- 1. refunds.method_changed_to ------------------------------------------------
alter table refunds add column if not exists method_changed_to text[];
comment on column refunds.method_changed_to is
  'Payment types this refund sent more to than the sale took that way (0104); null when none or before 0104';

-- 2. Functions ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_refund(p_sale_id uuid, p_lines jsonb, p_payments jsonb, p_reason text, p_note text, p_method_change_reason text DEFAULT NULL::text, p_approval_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  v_approver    uuid;
  v_rest        numeric;
  v_source      record;
  v_take        numeric;
  v_load_total  numeric := 0;
  v_load_lines  uuid[] := '{}';
  v_approved    record;
begin
  perform require_cents_each(p_payments, 'amount', 'Refund amount');
  -- The jobs whose charges come back are locked before the sale, the order
  -- change_paid_string_job takes them in (job, then its sales), so a refund
  -- and a string change on the same job queue instead of deadlocking (0079).
  perform 1 from string_jobs
   where id in (select sl.string_job_id from sale_lines sl
                 where sl.sale_id = p_sale_id and sl.string_job_id is not null
                   and sl.id in (select nullif(l->>'sale_line_id', '')::uuid
                                   from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) l))
   order by id for update;
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
      v_load_total := v_load_total + v_qty * v_price;
      v_load_lines := v_load_lines || v_sl.id;
    elsif v_sl.string_job_id is not null then
      -- The job stays on record, marked refunded. One not started yet is
      -- cancelled; one strung and waiting is delivered first.
      select * into v_job from string_jobs where id = v_sl.string_job_id for update;
      if v_sl.kind = 'string_change' then
        -- A string change's charge (0043) comes back once the job's own charge
        -- has (0079), or on its own once the job is delivered (0084). Either
        -- way it leaves the job as it is: refunding it alone would otherwise
        -- cancel a job that's still paid for.
        if v_job.refund_id is null and v_job.status <> 'delivered' then
          raise exception 'This is a string change on job J%: refund the job''s own charge first, or deliver the job',
            v_job.job_number;
        end if;
      else
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
    select a.refund_id is null and a.expires_at > now() as usable, a.approved_by, a.sale_id, a.amount,
           a.sale_line_ids
      into v_approved
      from refund_approvals a where a.id = p_approval_id
      for update;
    if not found or not coalesce(v_approved.usable, false) then
      raise exception 'The admin approval has expired or been used: ask again';
    end if;
    -- The approval covers one sale's loads, for the amount the admin saw.
    if v_approved.sale_id is distinct from p_sale_id then
      raise exception 'The admin approved a refund on another sale: ask again';
    end if;
    if abs(v_approved.amount - v_load_total) > 0.005 then
      raise exception 'The admin approved refunding $% of gift card loads, not $%: ask again',
        to_char(v_approved.amount, 'FM999999990.00'), to_char(v_load_total, 'FM999999990.00');
    end if;
    -- ...and the very loads they were shown, not another card for the same amount (0083).
    if (select coalesce(array_agg(x order by x), '{}') from unnest(v_approved.sale_line_ids) x)
       is distinct from (select coalesce(array_agg(x order by x), '{}') from unnest(v_load_lines) x) then
      raise exception 'The admin approved refunding other gift card loads on this sale: ask again';
    end if;
    v_approver := v_approved.approved_by;
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
  -- the new items, as 'exchange' refund payments. Each one records the
  -- payment type (a gift card by card) it came out of, up to what that type
  -- can still give back, taken cash, credit, gift card, store credit, check
  -- (0082). What no type covers stays an 'exchange' payment with no source.
  if coalesce(current_setting('acestock.exchange_id', true), '') <> '' then
    v_rest := v_total - v_paid;
    if v_rest < -0.005 then
      raise exception 'The money back ($%) is more than the return ($%)',
        to_char(v_paid, 'FM999999990.00'), to_char(v_total, 'FM999999990.00');
    end if;
    for v_source in
      select paid.method, paid.card, greatest(paid.amount - coalesce(back.amount, 0), 0) as left_amount
        from (select coalesce(sp.source_method, sp.method) as method,
                     case when coalesce(sp.source_method, sp.method) = 'gift_card'
                          then coalesce(sp.source_gift_card_id, sp.gift_card_id) end as card,
                     sum(sp.amount) as amount
                from sale_payments sp
               where sp.sale_id = p_sale_id and coalesce(sp.source_method, sp.method) <> 'exchange'
               group by 1, 2) paid
        left join (select coalesce(rp.source_method, rp.method) as method,
                          case when coalesce(rp.source_method, rp.method) = 'gift_card'
                               then coalesce(rp.source_gift_card_id, rp.gift_card_id) end as card,
                          sum(rp.amount) as amount
                     from refund_payments rp join refunds r on r.id = rp.refund_id
                    where r.sale_id = p_sale_id
                    group by 1, 2) back
          on back.method = paid.method and back.card is not distinct from paid.card
       order by array_position(array['cash', 'credit', 'gift_card', 'store_credit', 'check'], paid.method), paid.card
    loop
      exit when v_rest <= 0.005;
      v_take := least(v_rest, v_source.left_amount);
      if v_take > 0.005 then
        insert into refund_payments (refund_id, method, amount, source_method, source_gift_card_id)
        values (v_refund_id, 'exchange', v_take, v_source.method, v_source.card);
        v_paid := v_paid + v_take;
        v_rest := v_rest - v_take;
      end if;
    end loop;
    if v_rest > 0.005 then
      insert into refund_payments (refund_id, method, amount) values (v_refund_id, 'exchange', v_rest);
      v_paid := v_paid + v_rest;
    end if;
  end if;

  if abs(v_paid - v_total) > 0.005 then
    raise exception 'Refund payments (%) must equal the refund total (%)', v_paid, v_total;
  end if;

  -- A payment type this refund sends more to than the sale took that way (net
  -- of earlier refunds) is a payment-type change; a reason, if given, is kept
  -- with it (0093: no longer required).
  v_changed := refund_method_overages(p_sale_id, v_refund_id);

  if cardinality(v_changed) > 0 then
    update refunds
       set method_changed_to = v_changed,
           method_change_reason = nullif(trim(p_method_change_reason), '')
     where id = v_refund_id;
  end if;

  return v_refund_id;
end;
$function$;

revoke all on function record_refund(p_sale_id uuid, p_lines jsonb, p_payments jsonb, p_reason text, p_note text, p_method_change_reason text, p_approval_id uuid) from public, anon;
grant execute on function record_refund(p_sale_id uuid, p_lines jsonb, p_payments jsonb, p_reason text, p_note text, p_method_change_reason text, p_approval_id uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.change_paid_string_job(p_job_id uuid, p_main_product_id uuid, p_cross_product_id uuid, p_main_tension numeric, p_cross_tension numeric, p_payments jsonb, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
        update refunds
           set method_changed_to = v_changed,
               method_change_reason = nullif(trim(p_reason), '')
         where id = v_refund_id;
      end if;
      v_refund_ids := v_refund_ids || v_refund_id;
    end loop;

    return jsonb_build_object('direction', 'give_back', 'amount', v_amount, 'tax', v_tax, 'total', v_total,
                              'refund_ids', to_jsonb(v_refund_ids));
  end if;

  return jsonb_build_object('direction', 'none', 'amount', 0, 'tax', 0, 'total', 0);
end;
$function$;

revoke all on function change_paid_string_job(p_job_id uuid, p_main_product_id uuid, p_cross_product_id uuid, p_main_tension numeric, p_cross_tension numeric, p_payments jsonb, p_reason text) from public, anon;
grant execute on function change_paid_string_job(p_job_id uuid, p_main_product_id uuid, p_cross_product_id uuid, p_main_tension numeric, p_cross_tension numeric, p_payments jsonb, p_reason text) to authenticated;

CREATE OR REPLACE FUNCTION public.adjust_gift_card(p_gift_card_id uuid, p_amount numeric, p_reason text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_bal numeric;
begin
  if p_amount is null or p_amount = 0 then
    raise exception 'Adjustment amount must be non-zero';
  end if;
  perform require_cents(p_amount, 'Adjustment');
  perform 1 from gift_cards where id = p_gift_card_id for update;
  if not found then
    raise exception 'Unknown gift card %', p_gift_card_id;
  end if;

  -- Adding value is an admin's to give (0104); taking value off stays open to staff.
  if p_amount > 0 and auth.uid() is not null and not is_admin() then
    raise exception 'Only an admin can add value to a gift card'
      using errcode = '42501';
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
$function$;

revoke all on function adjust_gift_card(p_gift_card_id uuid, p_amount numeric, p_reason text) from public, anon;
grant execute on function adjust_gift_card(p_gift_card_id uuid, p_amount numeric, p_reason text) to authenticated;

CREATE OR REPLACE FUNCTION public.add_store_credit(p_customer_id uuid, p_amount numeric, p_reason text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'Store credit amount must be positive';
  end if;
  perform require_cents(p_amount, 'Store credit amount');
  if not exists (select 1 from customers where id = p_customer_id) then
    raise exception 'Unknown customer %', p_customer_id;
  end if;
  -- Store credit outside a refund is an admin's to give (0104).
  if auth.uid() is not null and not is_admin() then
    raise exception 'Only an admin can add store credit'
      using errcode = '42501';
  end if;
  insert into store_credit_txns (customer_id, amount, reason)
  values (p_customer_id, p_amount, coalesce(nullif(trim(p_reason), ''), 'adjust'));
  return (select coalesce(sum(amount), 0) from store_credit_txns where customer_id = p_customer_id);
end;
$function$;

revoke all on function add_store_credit(p_customer_id uuid, p_amount numeric, p_reason text) from public, anon;
grant execute on function add_store_credit(p_customer_id uuid, p_amount numeric, p_reason text) to authenticated;

-- 3. report_price_changes ------------------------------------------------------
create or replace function report_price_changes(p_from timestamptz, p_to timestamptz)
returns table (
  kind        text,
  sold_at     timestamptz,
  sale_id     uuid,
  made_by     text,
  approved_by text,
  item        text,
  qty         integer,
  from_price  numeric,
  to_price    numeric,
  amount      numeric,
  reason      text
)
language plpgsql
stable
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform require_admin();
  perform require_report_range(p_from, p_to);

  return query
  with lines as (
    select s.id as sid, s.sold_at as at, s.ticket_discount_reason,
           coalesce(maker.email, '(not recorded)') as maker,
           approver.email as approver,
           sl.id as line_id, sl.qty as n, sl.unit_price, sl.list_price, sl.price_reason, sl.discount_reason,
           coalesce(sl.price_before_discount, sl.unit_price) as before_discount,
           coalesce(sl.line_discount_each, 0) as line_each,
           coalesce(sl.ticket_discount_each, 0) as ticket_each,
           case
             when sl.product_id is not null then trim(coalesce(p.brand, '') || ' ' || p.name)
             when sl.string_job_id is not null then 'Stringing'
             else 'Gift card'
           end as item_name
      from sales s
      join sale_lines sl on sl.sale_id = s.id
      left join products p on p.id = sl.product_id
      left join profiles maker on maker.id = s.user_id
      left join profiles approver on approver.id = s.discount_approved_by
     where s.sold_at >= p_from and s.sold_at < p_to
  ),
  changes as (
    select 'price_change'::text as k, 1 as ord, l.*, l.list_price as was, l.before_discount as now_price,
           l.price_reason as why, null::text as ok_by
      from lines l
     where l.list_price is not null and l.before_discount <> l.list_price
    union all
    select 'line_discount', 2, l.*, l.before_discount, l.before_discount - l.line_each,
           l.discount_reason, l.approver
      from lines l
     where l.line_each > 0
    union all
    select 'ticket_discount', 3, l.*, l.before_discount - l.line_each, l.unit_price,
           l.ticket_discount_reason, l.approver
      from lines l
     where l.ticket_each > 0
  )
  select x.k, x.at, x.sid, x.maker, x.ok_by, x.item_name, x.n, x.was, x.now_price, x.taken, x.why
    from (
      select c.k, c.at, c.sid, c.maker, c.ok_by, c.item_name, c.n, c.was, c.now_price,
             c.n * (c.was - c.now_price) as taken,
             coalesce(nullif(trim(c.why), ''), '(none)') as why,
             c.line_id, c.ord
        from changes c
      union all
      -- A refund paid back a different way than the sale was paid (0104): no
      -- amount taken off, but who did it and when are on record.
      select 'payment_type_change', r.refunded_at, r.sale_id,
             coalesce(refunder.email, '(not recorded)'), null::text,
             'Refund paid by ' || array_to_string(array(
               select case m when 'credit' then 'card' when 'store_credit' then 'store credit'
                             when 'gift_card' then 'gift card' else m end
                 from unnest(r.method_changed_to) m), ', '),
             null::integer, null::numeric, null::numeric, null::numeric,
             coalesce(nullif(trim(r.method_change_reason), ''), '(none)'),
             null::uuid, 4
        from refunds r
        left join profiles refunder on refunder.id = r.user_id
       where r.method_changed_to is not null
         and r.refunded_at >= p_from and r.refunded_at < p_to
    ) x
   order by x.at, x.sid, x.item_name, x.line_id nulls last, x.ord;
end;
$$;

revoke all on function report_price_changes(timestamptz, timestamptz) from public, anon;
grant execute on function report_price_changes(timestamptz, timestamptz) to authenticated;
