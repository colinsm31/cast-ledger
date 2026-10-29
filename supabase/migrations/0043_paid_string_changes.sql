-- =============================================================================
-- 0043_paid_string_changes.sql — change the strings on a paid job and settle
--                                the difference (AceStock, commit 2b)
--
-- A job paid before it's strung can still have its strings changed. When the
-- new strings cost more or less, the difference is charged or given back in
-- the same step as the change, so a job's strings never drift from what was
-- paid:
--   • same price  → the strings just change;
--   • more        → a new sale with a "string change" line for the difference
--                   (plus stringing tax when that setting is on), paid by
--                   cash, credit and/or store credit;
--   • less        → a refund of the difference (plus the tax charged on it)
--                   against the sale(s) that paid for the job, newest first,
--                   as cash, credit and/or store credit. Each payment type can
--                   give back what that sale took that way; more needs a reason
--                   (the Phase 1B refund rule).
--
-- The difference is between the strings' catalog prices (labor + each distinct
-- string), recorded when the strings are chosen, so a discount given at the
-- register carries over and later catalog price changes don't count.
--
-- Supporting changes:
--   1. string_jobs.strings_price — the catalog price of the job's strings.
--   2. sale_lines.kind ('charge' | 'string_change') and sale_lines.taxable;
--      refund_lines.kind ('return' | 'string_change').
--   3. record_sale saves what was charged as the job's price and marks each
--      line taxed or not.
--   4. Refund tax and the payment-type rule move into shared helpers, used by
--      record_refund and by string-change give-backs. Refund tax now counts
--      only taxable refunded amounts (stringing may be untaxed).
--   5. A paid job's strings can change directly only at the same price; any
--      other change goes through change_paid_string_job.
--
-- Re-runnable.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- 1. Columns
-- ----------------------------------------------------------------------------
alter table string_jobs add column if not exists strings_price numeric(12, 2);

alter table sale_lines add column if not exists kind text not null default 'charge';
alter table sale_lines drop constraint if exists sale_lines_kind_check;
alter table sale_lines add constraint sale_lines_kind_check
  check (kind in ('charge', 'string_change') and (kind = 'charge' or string_job_id is not null));

alter table sale_lines add column if not exists taxable boolean;

alter table refund_lines add column if not exists kind text not null default 'return';
alter table refund_lines drop constraint if exists refund_lines_kind_check;
alter table refund_lines add constraint refund_lines_kind_check check (kind in ('return', 'string_change'));

-- ----------------------------------------------------------------------------
-- 2. The catalog price of a pair of strings: labor + each distinct string.
-- ----------------------------------------------------------------------------
create or replace function string_job_strings_price(p_main_product_id uuid, p_cross_product_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select round(
           coalesce((select stringing_labor from settings where id), 0)
         + coalesce((select sum(coalesce(p.sell_price, 0))
                       from products p
                      where p.id in (select distinct x
                                       from (values (p_main_product_id), (p_cross_product_id)) t(x)
                                      where x is not null)), 0),
         2);
$$;

revoke all on function string_job_strings_price(uuid, uuid) from public, anon;
grant execute on function string_job_strings_price(uuid, uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. Backfill
-- ----------------------------------------------------------------------------
-- Existing jobs: today's catalog price of their strings.
update string_jobs
   set strings_price = string_job_strings_price(main_product_id, cross_product_id)
 where strings_price is null;

-- Existing lines: products are taxed, gift card loads aren't; a stringing line
-- was taxed when its sale charged more tax than its product lines alone.
update sale_lines sl
   set taxable = case
     when sl.product_id is not null then true
     when sl.gift_card_id is not null then false
     else coalesce((
       select s.tax > round(coalesce((select sum(p.qty * p.unit_price) from sale_lines p
                                       where p.sale_id = s.id and p.product_id is not null), 0)
                            * coalesce(s.tax_rate, 0) / 100.0, 2) + 0.005
         from sales s where s.id = sl.sale_id), false)
   end
 where sl.taxable is null;

alter table sale_lines alter column taxable set default true;
alter table sale_lines alter column taxable set not null;

-- ----------------------------------------------------------------------------
-- 4. Shared refund rules
-- ----------------------------------------------------------------------------
-- Tax for a refund of p_taxable (the taxable part of it) from a sale: tax on
-- everything taxable refunded so far, rounded once, minus tax already refunded,
-- never beyond what the sale charged. p_refund_id is the refund being built
-- (its own lines and tax are left out of "so far").
create or replace function sale_refund_tax(p_sale_id uuid, p_taxable numeric, p_refund_id uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rate      numeric;
  v_sale_tax  numeric;
  v_prev_sub  numeric;
  v_prev_tax  numeric;
begin
  select coalesce(tax_rate, 0), coalesce(tax, 0) into v_rate, v_sale_tax from sales where id = p_sale_id;
  select coalesce(sum(rl.qty * rl.unit_price), 0) into v_prev_sub
    from refund_lines rl
    join refunds r on r.id = rl.refund_id
    join sale_lines sl on sl.id = rl.sale_line_id
   where r.sale_id = p_sale_id and r.id is distinct from p_refund_id and sl.taxable;
  select coalesce(sum(tax), 0) into v_prev_tax
    from refunds where sale_id = p_sale_id and id is distinct from p_refund_id;
  return greatest(0, least(round((v_prev_sub + p_taxable) * v_rate / 100.0, 2), v_sale_tax) - v_prev_tax);
end;
$$;

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
    from (values ('cash'), ('credit'), ('gift_card'), ('store_credit')) as m(method);
$$;

-- The payment types a refund sends more to than the sale took that way (net of
-- earlier refunds): each is a payment-type change and needs a reason. Only
-- types this refund pays out to count, so an earlier, already-explained change
-- doesn't follow later refunds around.
create or replace function refund_method_overages(p_sale_id uuid, p_refund_id uuid)
returns text[]
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(b.method order by b.method), '{}')
    from sale_refundable_by_method(p_sale_id, p_refund_id) b
   where (select coalesce(sum(rp.amount), 0) from refund_payments rp
           where rp.refund_id = p_refund_id and rp.method = b.method) > b.refundable + 0.005;
$$;

revoke all on function sale_refund_tax(uuid, numeric, uuid) from public, anon;
revoke all on function sale_refundable_by_method(uuid, uuid) from public, anon;
revoke all on function refund_method_overages(uuid, uuid) from public, anon;
grant execute on function sale_refund_tax(uuid, numeric, uuid) to authenticated;
grant execute on function sale_refundable_by_method(uuid, uuid) to authenticated;
grant execute on function refund_method_overages(uuid, uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. What a string change would cost: a quote, used by the screen to show the
--    amount and by change_paid_string_job to charge or give it back.
--
--    { "direction": "none" | "charge" | "give_back",
--      "amount": pre-tax difference, "tax": ..., "total": ...,
--      "old_price", "new_price", "customer_id": store credit goes here,
--      "refundable": { method: amount, ... }        -- give_back only
--      "allocations": [ { sale_id, sale_line_id, amount, tax }, ... ] }  -- newest sale first
-- ----------------------------------------------------------------------------
create or replace function string_change_quote(
  p_job_id           uuid,
  p_main_product_id  uuid,
  p_cross_product_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_job        string_jobs%rowtype;
  v_customer   uuid;
  v_old        numeric;
  v_new        numeric;
  v_diff       numeric;
  v_rate       numeric;
  v_tax_string boolean;
  v_tax        numeric;
  v_left       numeric;
  v_portion    numeric;
  v_portion_tx numeric;
  v_sale       record;
  v_allocs     jsonb := '[]'::jsonb;
  v_given      numeric := 0;
  v_given_tax  numeric := 0;
  v_refundable jsonb := '{}'::jsonb;
begin
  perform require_staff();

  select * into v_job from string_jobs where id = p_job_id;
  if not found then
    raise exception 'Unknown string job %', p_job_id;
  end if;
  if v_job.paid_sale_id is null or v_job.status <> 'entered' then
    raise exception 'Only a paid job that hasn''t been strung yet can change strings this way';
  end if;
  if p_main_product_id is null or p_cross_product_id is null then
    raise exception 'Choose the mains and crosses strings from the catalog';
  end if;

  -- Store credit goes to whoever paid for the job, else the racquet's owner.
  select coalesce(s.customer_id, r.customer_id) into v_customer
    from string_jobs j
    join customer_rackets r on r.id = j.customer_racket_id
    left join sales s on s.id = j.paid_sale_id
   where j.id = p_job_id;

  v_old  := coalesce(v_job.strings_price, string_job_strings_price(v_job.main_product_id, v_job.cross_product_id));
  v_new  := string_job_strings_price(p_main_product_id, p_cross_product_id);
  v_diff := v_new - v_old;

  if v_diff = 0 then
    return jsonb_build_object('direction', 'none', 'amount', 0, 'tax', 0, 'total', 0,
                              'old_price', v_old, 'new_price', v_new, 'customer_id', v_customer);
  end if;

  if v_diff > 0 then
    select coalesce(tax_rate, 0), coalesce(tax_stringing, false) into v_rate, v_tax_string from settings where id;
    v_tax := case when v_tax_string then round(v_diff * v_rate / 100.0, 2) else 0 end;
    return jsonb_build_object('direction', 'charge', 'amount', v_diff, 'tax', v_tax, 'total', v_diff + v_tax,
                              'old_price', v_old, 'new_price', v_new, 'customer_id', v_customer);
  end if;

  -- Give back -v_diff from the sales that paid for the job, newest first, never
  -- more than a sale took for this job (net of earlier give-backs).
  v_left := -v_diff;
  for v_sale in
    select sl.sale_id,
           (array_agg(sl.id order by sl.created_at desc))[1] as sale_line_id,
           bool_or(sl.taxable) as taxable,
           sum(sl.qty * sl.unit_price)
             - coalesce((select sum(rl.qty * rl.unit_price) from refund_lines rl
                          where rl.kind = 'string_change'
                            and rl.sale_line_id in (select x.id from sale_lines x
                                                     where x.sale_id = sl.sale_id and x.string_job_id = p_job_id)), 0)
             as job_net
      from sale_lines sl
      join sales s on s.id = sl.sale_id
     where sl.string_job_id = p_job_id
     group by sl.sale_id, s.sold_at
     order by s.sold_at desc
  loop
    exit when v_left <= 0;
    v_portion := least(v_left, greatest(v_sale.job_net, 0));
    continue when v_portion <= 0;
    v_portion_tx := sale_refund_tax(v_sale.sale_id, case when v_sale.taxable then v_portion else 0 end, null);
    v_allocs := v_allocs || jsonb_build_object('sale_id', v_sale.sale_id, 'sale_line_id', v_sale.sale_line_id,
                                               'amount', v_portion, 'tax', v_portion_tx);
    v_given := v_given + v_portion;
    v_given_tax := v_given_tax + v_portion_tx;
    v_left := v_left - v_portion;

    -- What each payment type can give back, summed over the sales used.
    select v_refundable || coalesce(jsonb_object_agg(b.method, coalesce((v_refundable->>b.method)::numeric, 0) + b.refundable), '{}'::jsonb)
      into v_refundable
      from sale_refundable_by_method(v_sale.sale_id, null) b;
  end loop;

  return jsonb_build_object('direction', 'give_back', 'amount', v_given, 'tax', v_given_tax,
                            'total', v_given + v_given_tax, 'old_price', v_old, 'new_price', v_new,
                            'customer_id', v_customer, 'refundable', v_refundable, 'allocations', v_allocs);
end;
$$;

revoke all on function string_change_quote(uuid, uuid, uuid) from public, anon;
grant execute on function string_change_quote(uuid, uuid, uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 6. change_paid_string_job — change a paid, not-yet-strung job's strings and
--    settle the difference in one step. Returns
--    { direction, amount, tax, total, sale_id | refund_ids }.
-- ----------------------------------------------------------------------------
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

revoke all on function change_paid_string_job(uuid, uuid, uuid, numeric, numeric, jsonb, text) from public, anon;
grant execute on function change_paid_string_job(uuid, uuid, uuid, numeric, numeric, jsonb, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 7. A paid job's price changes only through change_paid_string_job.
--    (Same as 0038 otherwise.)
-- ----------------------------------------------------------------------------
create or replace function guard_paid_string_job()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if old.paid_sale_id is not null then
    if new.paid_sale_id is distinct from old.paid_sale_id then
      raise exception 'String job % is already paid by sale %', old.id, old.paid_sale_id;
    end if;
    if new.price is distinct from old.price
       and coalesce(current_setting('acestock.string_change_job', true), '') <> old.id::text then
      raise exception 'The price of a paid string job can''t be changed';
    end if;
  end if;
  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- 8. The entry rules (0042) also record the strings' catalog price, and keep a
--    paid job's strings at the price that was paid unless the change goes
--    through change_paid_string_job.
-- ----------------------------------------------------------------------------
create or replace function guard_string_job_strings()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_main          record;
  v_cross         record;
  v_check_main    boolean;
  v_check_cross   boolean;
  v_strings_moved boolean;
  v_new_price     numeric;
  v_old_price     numeric;
begin
  -- Only entered jobs, and only writes by a signed-in user. A strung job's
  -- strings are refused by trg_guard_strung_job_strings.
  if auth.uid() is null or new.status <> 'entered' then
    return new;
  end if;

  if new.main_product_id is null or new.cross_product_id is null then
    raise exception 'Choose the mains and crosses strings from the catalog';
  end if;
  if new.main_tension is null or new.cross_tension is null then
    raise exception 'Enter the mains and crosses tension';
  end if;

  -- Availability is checked for strings the job doesn't already hold.
  v_check_main := tg_op = 'INSERT'
    or (new.main_product_id is distinct from old.main_product_id
        and new.main_product_id is distinct from old.cross_product_id);
  v_check_cross := new.cross_product_id <> new.main_product_id
    and (tg_op = 'INSERT'
         or (new.cross_product_id is distinct from old.main_product_id
             and new.cross_product_id is distinct from old.cross_product_id));

  -- Each call locks its string; take them in id order so two registers
  -- choosing the same pair of strings can't deadlock.
  if new.cross_product_id < new.main_product_id then
    select * into v_cross from string_job_side(new.cross_product_id, new.id, v_check_cross, 'crosses');
    select * into v_main  from string_job_side(new.main_product_id,  new.id, v_check_main,  'mains');
  else
    select * into v_main  from string_job_side(new.main_product_id,  new.id, v_check_main,  'mains');
    select * into v_cross from string_job_side(new.cross_product_id, new.id, v_check_cross, 'crosses');
  end if;

  new.main_brand   := v_main.brand;
  new.main_string  := v_main.name;
  new.main_specs   := v_main.specs;
  new.cross_brand  := v_cross.brand;
  new.cross_string := v_cross.name;
  new.cross_specs  := v_cross.specs;

  -- Record the strings' catalog price when they're chosen (not on a
  -- tension-only edit, so later catalog price changes don't count).
  v_strings_moved := tg_op = 'INSERT'
    or (new.main_product_id, new.cross_product_id) is distinct from (old.main_product_id, old.cross_product_id);
  if v_strings_moved then
    v_new_price := string_job_strings_price(new.main_product_id, new.cross_product_id);
    if tg_op = 'UPDATE' and old.paid_sale_id is not null
       and coalesce(current_setting('acestock.string_change_job', true), '') <> old.id::text then
      v_old_price := coalesce(old.strings_price, string_job_strings_price(old.main_product_id, old.cross_product_id));
      if v_new_price <> v_old_price then
        raise exception 'This job was paid for strings costing $%; the new strings cost $%. Use String change to settle the difference',
          to_char(v_old_price, 'FM999999990.00'), to_char(v_new_price, 'FM999999990.00');
      end if;
    end if;
    new.strings_price := v_new_price;
  end if;
  return new;
end;
$$;

revoke all on function guard_paid_string_job() from public, anon, authenticated;
revoke all on function guard_string_job_strings() from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 9. record_sale — same as 0042, plus: a paid job's price becomes what was
--    charged, and each line records whether it was taxed.
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

-- ----------------------------------------------------------------------------
-- 10. record_refund — same as 0038 (owner rights per 0040), plus: tax and the
--     payment-type rule come from the shared helpers, so tax counts only
--     taxable refunded amounts; returned quantities count product returns only.
-- ----------------------------------------------------------------------------
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

-- ----------------------------------------------------------------------------
-- 11. Grants: signed-in staff only (as 0040/0041).
-- ----------------------------------------------------------------------------
revoke all on function record_sale(jsonb, uuid, jsonb, text) from public, anon;
revoke all on function record_refund(uuid, jsonb, jsonb, text, text, text) from public, anon;
grant execute on function record_sale(jsonb, uuid, jsonb, text) to authenticated;
grant execute on function record_refund(uuid, jsonb, jsonb, text, text, text) to authenticated;
