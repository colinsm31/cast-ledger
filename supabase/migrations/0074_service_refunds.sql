-- =============================================================================
-- 0074_service_refunds.sql — refund a stringing charge (AceStock, Phase 3D)
--
-- Before:
--   • record_refund refused every line that wasn't a product ("Only product
--     lines can be returned"), so a stringing charge couldn't be given back.
--   • A paid job couldn't be cancelled either ("This string job has been
--     paid, so it can't be cancelled"), so a prepaid job the customer no
--     longer wanted had no way out.
--   • Refund tax counted every refunded line as taxed.
--
-- Now (record_refund, otherwise the same as 0070):
--   1. A stringing line (a job's charge, or a string-change charge) can be
--      refunded whole, once. It gives back the line's price less any
--      string-change give-backs already made against it.
--   2. The job stays on record, marked refunded (string_jobs.refunded_at,
--      refund_id). A job not started yet is cancelled by the refund; one
--      strung and waiting must be delivered first; a delivered or cancelled
--      job is just marked.
--   3. Refund tax counts only lines the sale taxed (stringing may be untaxed).
--   4. cancel_string_job on a paid job points to the refund instead.
--   5. A new job can't be entered already refunded.
--
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Columns
-- -----------------------------------------------------------------------------
alter table string_jobs add column if not exists refunded_at timestamptz;
alter table string_jobs add column if not exists refund_id uuid references refunds (id);
create index if not exists idx_string_jobs_refund on string_jobs (refund_id) where refund_id is not null;

comment on column string_jobs.refunded_at is 'When the job''s charge was refunded; the job stays on record';
comment on column string_jobs.refund_id is 'The refund that gave back the job''s charge';

-- -----------------------------------------------------------------------------
-- 2. guard_new_string_job — same as 0040, plus the refund columns
-- -----------------------------------------------------------------------------
create or replace function guard_new_string_job()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if current_user in ('authenticated', 'anon') then
    if new.status <> 'entered'
       or new.paid_sale_id is not null
       or new.completed_at is not null or new.completed_by is not null
       or new.delivered_at is not null or new.delivered_by is not null
       or new.cancelled_at is not null or new.cancelled_by is not null
       or new.refunded_at is not null or new.refund_id is not null then
      raise exception 'A new string job starts as entered and unpaid';
    end if;
    new.entered_by := auth.uid();
    new.entered_at := now();
  end if;
  return new;
end;
$$;

revoke all on function guard_new_string_job() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. record_refund — same as 0070, plus stringing lines
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
  v_unit_to     text;
  v_unit_reason text;
  v_unit        product_units%rowtype;
  v_job         string_jobs%rowtype;
  v_price       numeric;
  v_taxable     numeric := 0;
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
    if v_sl.product_id is null and v_sl.string_job_id is null then
      raise exception 'Only product and stringing lines can be returned';
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

    if v_sl.string_job_id is not null then
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


revoke all on function record_refund(uuid, jsonb, jsonb, text, text, text) from public, anon;
grant execute on function record_refund(uuid, jsonb, jsonb, text, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 4. cancel_string_job — same as 0042; a paid job points to its refund
-- -----------------------------------------------------------------------------
create or replace function cancel_string_job(p_job_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_current text;
  v_paid    uuid;
begin
  perform require_staff();

  select status, paid_sale_id into v_current, v_paid
    from string_jobs where id = p_job_id
    for update;
  if not found then
    raise exception 'Unknown string job %', p_job_id;
  end if;
  if v_current <> 'entered' then
    raise exception 'Only an entered job can be cancelled (this one is "%")', v_current;
  end if;
  if v_paid is not null then
    -- Refunding its charge from the sale cancels it (0074), so the money and
    -- the job are settled together.
    raise exception 'This string job has been paid: refund its charge from the sale to cancel it';
  end if;

  update string_jobs
     set status       = 'cancelled',
         cancelled_at = now(),
         cancelled_by = auth.uid()
   where id = p_job_id
     and status = 'entered';
  return 'cancelled';
end;
$$;


revoke all on function cancel_string_job(uuid) from public, anon;
grant execute on function cancel_string_job(uuid) to authenticated;
