-- =============================================================================
-- 0075_gift_card_load_refunds.sql — refund an unused gift card load with an
-- admin's approval (AceStock, Phase 3D)
--
-- Before:
--   • record_refund refused a gift card load line ("Only product and
--     stringing lines can be returned"), so money put on a card by mistake
--     stayed there.
--
-- Now:
--   1. A gift card load can be refunded whole while the card still holds all
--      of it. The load comes back off the card ('load refund'), and a card
--      left empty is no longer anyone's (as when it's spent, record_sale).
--      The money can't go back onto the same card.
--   2. It needs an admin: one signed in at the register, or a one-time
--      approval (refund_approvals, approve_refund) that lasts 15 minutes and
--      is used up by the refund. refunds.approved_by records who.
--   3. record_refund gains p_approval_id (default null); otherwise the same
--      as 0074.
--
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Approvals
-- -----------------------------------------------------------------------------
create table if not exists refund_approvals (
  id           uuid primary key default gen_random_uuid(),
  approved_by  uuid not null default auth.uid() references profiles (id),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '15 minutes',
  refund_id    uuid references refunds (id)
);
comment on table refund_approvals is 'One-time admin approvals for refunding a gift card load';

alter table refund_approvals enable row level security;
drop policy if exists refund_approvals_admin_select on refund_approvals;
drop policy if exists refund_approvals_admin_insert on refund_approvals;
create policy refund_approvals_admin_select on refund_approvals
  for select to authenticated using (is_admin());
create policy refund_approvals_admin_insert on refund_approvals
  for insert to authenticated with check (is_admin() and approved_by = auth.uid() and refund_id is null);
revoke all on refund_approvals from anon, authenticated;
grant select, insert on refund_approvals to authenticated;

drop trigger if exists trg_enforce_staff_writer on refund_approvals;
create trigger trg_enforce_staff_writer before insert or update or delete on refund_approvals
  for each statement execute function enforce_staff_writer();

alter table refunds add column if not exists approved_by uuid references profiles (id);
comment on column refunds.approved_by is 'The admin who approved refunding a gift card load';

create or replace function approve_refund()
returns uuid
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if not is_admin() then
    raise exception 'Only an admin can approve refunding a gift card load' using errcode = '42501';
  end if;
  insert into refund_approvals default values returning id into v_id;
  return v_id;
end;
$$;

revoke all on function approve_refund() from public, anon;
grant execute on function approve_refund() to authenticated;

-- -----------------------------------------------------------------------------
-- 2. record_refund — same as 0074, plus gift card loads and p_approval_id
-- -----------------------------------------------------------------------------
drop function if exists record_refund(uuid, jsonb, jsonb, text, text, text);

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
