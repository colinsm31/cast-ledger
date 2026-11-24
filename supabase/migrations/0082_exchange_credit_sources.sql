-- =============================================================================
-- 0082_exchange_credit_sources.sql — an exchange's credit keeps the payment
-- types it came from (AceStock, Phase 3D second review)
--
-- Before (0081): a later refund of an exchange's new sale could send its
-- credit back the way the original sale was paid, but nothing took that off
-- the original. One credit could go back twice without a reason: a $30 card
-- charge could have $40 put back on the card. Two exchanges from one sale
-- shared the same allowance, and chained exchanges and gift-card-paid
-- originals always asked for a reason.
--
-- Now:
--   1. refund_payments and sale_payments gain source_method and
--      source_gift_card_id, set only on 'exchange' payments: the payment type
--      (a gift card by card) that part of the credit came out of.
--   2. record_refund, in an exchange, splits the credit across the original
--      sale's payment types up to what each can still give back (cash, credit,
--      gift card, store credit, check); record_exchange copies that split onto
--      the new sale's exchange payments.
--   3. sale_refundable_by_method and refund_method_overages count an exchange
--      payment as its source: it uses up the original's room that way and
--      gives the new sale exactly that room. 0081's allowance is gone.
--   Exchanges recorded before this have no source, so a later refund of their
--   new sale needs a reason for that part (as before 0081).
--
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Where an exchange payment came from
-- -----------------------------------------------------------------------------
-- No foreign key on source_gift_card_id: it copies a card already recorded on
-- the original payment, and a second key to gift_cards would make the API's
-- existing gift_cards ( ... ) embeds on payments ambiguous.
alter table sale_payments add column if not exists source_method text;
alter table sale_payments add column if not exists source_gift_card_id uuid;
alter table refund_payments add column if not exists source_method text;
alter table refund_payments add column if not exists source_gift_card_id uuid;

alter table sale_payments drop constraint if exists ck_sale_payments_source;
alter table sale_payments add constraint ck_sale_payments_source check (
  (source_method is null or (method = 'exchange'
     and source_method in ('cash', 'credit', 'gift_card', 'store_credit', 'check')))
  and ((source_gift_card_id is not null) = (source_method is not distinct from 'gift_card')));
alter table refund_payments drop constraint if exists ck_refund_payments_source;
alter table refund_payments add constraint ck_refund_payments_source check (
  (source_method is null or (method = 'exchange'
     and source_method in ('cash', 'credit', 'gift_card', 'store_credit', 'check')))
  and ((source_gift_card_id is not null) = (source_method is not distinct from 'gift_card')));

comment on column sale_payments.source_method is 'For an exchange payment: the payment type of the original sale it came from';
comment on column sale_payments.source_gift_card_id is 'For an exchange payment from a gift card: that card';
comment on column refund_payments.source_method is 'For an exchange payment: the payment type of this sale it came out of';
comment on column refund_payments.source_gift_card_id is 'For an exchange payment from a gift card: that card';

-- -----------------------------------------------------------------------------
-- 2. sale_refundable_by_method — an exchange payment counts as its source
-- -----------------------------------------------------------------------------
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
                      where sp.sale_id = p_sale_id and coalesce(sp.source_method, sp.method) = m.method), 0)
         - coalesce((select sum(rp.amount) from refund_payments rp join refunds r on r.id = rp.refund_id
                      where r.sale_id = p_sale_id and r.id is distinct from p_refund_id
                        and coalesce(rp.source_method, rp.method) = m.method), 0),
           0)
    from (values ('cash'), ('credit'), ('gift_card'), ('store_credit'), ('check')) as m(method);
$$;

revoke all on function sale_refundable_by_method(uuid, uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. refund_method_overages — same as 0046; a gift card's room counts the
--    exchange payments that came from it
-- -----------------------------------------------------------------------------
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
                          where sp.sale_id = p_sale_id and coalesce(sp.source_method, sp.method) = 'gift_card'
                            and coalesce(sp.source_gift_card_id, sp.gift_card_id) = c.gift_card_id), 0)
             - coalesce((select sum(rp.amount) from refund_payments rp join refunds r on r.id = rp.refund_id
                          where r.sale_id = p_sale_id and r.id is distinct from p_refund_id
                            and coalesce(rp.source_method, rp.method) = 'gift_card'
                            and coalesce(rp.source_gift_card_id, rp.gift_card_id) = c.gift_card_id), 0),
               0) + 0.005
    ) x;
$$;

revoke all on function refund_method_overages(uuid, uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4. record_refund — same as 0079; an exchange's credit is split by source
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
  v_approver    uuid;
  v_rest        numeric;
  v_source      record;
  v_take        numeric;
  v_load_total  numeric := 0;
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
    elsif v_sl.string_job_id is not null then
      -- The job stays on record, marked refunded. One not started yet is
      -- cancelled; one strung and waiting is delivered first.
      select * into v_job from string_jobs where id = v_sl.string_job_id for update;
      -- A string change's charge (0043) comes back once the job's own charge
      -- has: refunding it alone would cancel a job that's still paid for (0079).
      if v_sl.kind = 'string_change' and v_job.refund_id is null then
        raise exception 'This is a string change on job J%: refund the job''s own charge first',
          v_job.job_number;
      end if;
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
    select a.refund_id is null and a.expires_at > now() as usable, a.approved_by, a.sale_id, a.amount
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
-- 5. record_exchange — same as 0081; the new sale's exchange payments are split
-- -----------------------------------------------------------------------------
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

  -- The return's credit buys goods, not gift card value: a load would turn a
  -- card or cash purchase into gift card money without the reason a refund
  -- onto a gift card needs (0081).
  if jsonb_typeof(p_new_lines) = 'array' and exists (
       select 1 from jsonb_array_elements(p_new_lines) l where nullif(l->>'gift_card_id', '') is not null) then
    raise exception 'An exchange can''t load a gift card: refund the items onto the card instead';
  end if;

  -- record_refund and record_sale read these transaction-local settings.
  -- Only this function sets them: the API can't call set_config (pg_catalog
  -- isn't exposed), and nothing else sets acestock.exchange_*.
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

  -- The credit arrives as one 'exchange' payment (record_sale); it's
  -- replaced by the refund's split, so each part keeps the payment type it
  -- came from (0082).
  delete from sale_payments where sale_id = v_sale_id and method = 'exchange';
  insert into sale_payments (sale_id, method, amount, source_method, source_gift_card_id)
  select v_sale_id, 'exchange', rp.amount, rp.source_method, rp.source_gift_card_id
    from refund_payments rp
   where rp.refund_id = v_refund_id and rp.method = 'exchange';

  insert into exchanges (id, refund_id, sale_id, credit) values (v_exchange_id, v_refund_id, v_sale_id, v_credit);

  return jsonb_build_object('exchange_id', v_exchange_id, 'refund_id', v_refund_id, 'sale_id', v_sale_id,
                            'credit', v_credit);
end;
$$;

revoke all on function record_exchange(uuid, jsonb, jsonb, uuid, jsonb, jsonb, text, jsonb, uuid, text, uuid) from public, anon;
grant execute on function record_exchange(uuid, jsonb, jsonb, uuid, jsonb, jsonb, text, jsonb, uuid, text, uuid) to authenticated;
