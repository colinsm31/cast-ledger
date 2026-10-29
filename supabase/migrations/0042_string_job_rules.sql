-- =============================================================================
-- 0042_string_job_rules.sql — the string-job lifecycle, enforced by the server
--                             (AceStock, foundation code review #2, #3, #10,
--                              #19 for strings, #20)
--
-- Before, several rules lived only in the screens:
--   • A paid job could be cancelled (#2). Refunds only cover product lines, so
--     the customer's payment had nowhere to go.
--   • advance_string_job ranked statuses entered 0 → complete 1 → delivered 2
--     and allowed "one step forward". A cancelled job ranked -1, so moving it
--     to 'entered' passed and revived it (#3).
--   • Neither function locked the job, so two "Complete" clicks at the same
--     moment both passed the status check and used up string twice (#3).
--   • A job could be delivered without being paid, its strings edited after
--     it was strung, and a job entered on a retired racquet or as a second
--     open job on the same racquet (#20).
--   • A string-job line on a sale could have qty > 1 (#10).
--   • A job could be entered with a partly chosen string (no color or gauge)
--     or no tension, so no catalog string was set aside or used up, and a
--     string with nothing available could be picked even with "block
--     overselling" on (#19).
--
-- Now:
--   1. advance_string_job allows only entered → complete and complete →
--      delivered, locks the job first, and refuses delivery until it's paid.
--   2. cancel_string_job locks the job and refuses a paid one.
--   3. A job's strings can't change once it's no longer 'entered' (price,
--      notes and stringer still can; a paid job's price stays locked by 0038).
--   4. A new job needs an active racquet with no other open (entered or
--      complete) job. A unique index backs this up.
--   5. Strings have two default attributes, color and gauge (material and
--      length are removed).
--   6. A job entered or edited by a signed-in user needs a catalog string for
--      mains and crosses, with every string attribute set, both active, and
--      both tensions. The job's brand, string name and attribute values are
--      copied from the catalog string. With "block overselling" on, a newly
--      chosen string must have at least one unit available (on hand minus
--      what other entered jobs have set aside); the string's row is locked
--      first so two registers can't both take the last unit.
--   7. record_sale charges a string job with qty 1 only.
--
-- The job's own price isn't forced onto the sale line yet: any line's price
-- can be changed at the register until recorded price overrides (Phase 2A).
--
-- Re-runnable.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- 1. advance_string_job — explicit transitions, row lock, paid before delivery.
-- ----------------------------------------------------------------------------
create or replace function advance_string_job(
  p_job_id        uuid,
  p_target_status text
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_current text;
  v_main    uuid;
  v_cross   uuid;
  v_paid    uuid;
begin
  perform require_staff();

  if p_target_status is null
     or p_target_status not in ('entered', 'complete', 'delivered', 'cancelled') then
    raise exception 'Invalid status "%"', p_target_status;
  end if;

  -- Lock the job so a second click (or register) waits, then sees this one's result.
  select status, main_product_id, cross_product_id, paid_sale_id
    into v_current, v_main, v_cross, v_paid
    from string_jobs where id = p_job_id
    for update;
  if not found then
    raise exception 'Unknown string job %', p_job_id;
  end if;

  if (v_current, p_target_status) not in (('entered', 'complete'), ('complete', 'delivered')) then
    raise exception 'Cannot move a string job from "%" to "%"', v_current, p_target_status;
  end if;
  if p_target_status = 'delivered' and v_paid is null then
    raise exception 'Take payment for this string job before marking it delivered';
  end if;

  update string_jobs
    set status       = p_target_status,
        completed_at = case when p_target_status = 'complete'  then now()      else completed_at end,
        completed_by = case when p_target_status = 'complete'  then auth.uid() else completed_by end,
        delivered_at = case when p_target_status = 'delivered' then now()      else delivered_at end,
        delivered_by = case when p_target_status = 'delivered' then auth.uid() else delivered_by end
  where id = p_job_id
    and status = v_current;

  -- Consume one unit of each distinct catalog string the job used.
  if p_target_status = 'complete' then
    insert into inventory_txns (txn_type, product_id, qty, note)
    select 'consume', pid, -1, 'String job completed'
    from (
      select distinct pid
      from (values (v_main), (v_cross)) as t(pid)
      where pid is not null
    ) d;
  end if;

  return p_target_status;
end;
$$;

-- ----------------------------------------------------------------------------
-- 2. cancel_string_job — row lock; a paid job can't be cancelled.
-- ----------------------------------------------------------------------------
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
    -- Refunds return product lines only, so cancelling would strand the payment.
    raise exception 'This string job has been paid, so it can''t be cancelled';
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

-- ----------------------------------------------------------------------------
-- 3. Strings are fixed once the job has been strung.
-- ----------------------------------------------------------------------------
create or replace function guard_strung_job_strings()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if old.status <> 'entered'
     and (new.main_product_id, new.main_brand, new.main_string, new.main_specs, new.main_tension,
          new.cross_product_id, new.cross_brand, new.cross_string, new.cross_specs, new.cross_tension)
         is distinct from
         (old.main_product_id, old.main_brand, old.main_string, old.main_specs, old.main_tension,
          old.cross_product_id, old.cross_brand, old.cross_string, old.cross_specs, old.cross_tension) then
    raise exception 'The strings on a % string job can''t be changed', old.status;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_strung_job_strings on string_jobs;
create trigger trg_guard_strung_job_strings
  before update of main_product_id, main_brand, main_string, main_specs, main_tension,
                   cross_product_id, cross_brand, cross_string, cross_specs, cross_tension
  on string_jobs
  for each row execute function guard_strung_job_strings();

-- ----------------------------------------------------------------------------
-- 4. A new job needs an active racquet with no other open job.
--    Owner rights so the racquet row can be locked: two registers entering a
--    job for the same racquet at once are serialized and the second gets the
--    message below. The unique index is the backstop.
-- ----------------------------------------------------------------------------
create or replace function guard_string_job_racket()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_active boolean;
begin
  select is_active into v_active
    from customer_rackets where id = new.customer_racket_id
    for update;
  if not found then
    return new;  -- the foreign key reports an unknown racquet
  end if;
  if not v_active then
    raise exception 'This racquet has been retired, so it can''t get a new string job';
  end if;
  if new.status in ('entered', 'complete') and exists (
       select 1 from string_jobs
        where customer_racket_id = new.customer_racket_id
          and status in ('entered', 'complete')) then
    raise exception 'This racquet already has an open string job';
  end if;
  return new;
end;
$$;

revoke all on function guard_strung_job_strings() from public, anon, authenticated;
revoke all on function guard_string_job_racket() from public, anon, authenticated;

drop trigger if exists trg_guard_string_job_racket on string_jobs;
create trigger trg_guard_string_job_racket
  before insert on string_jobs
  for each row execute function guard_string_job_racket();

create unique index if not exists uq_string_jobs_one_open_per_racket
  on string_jobs (customer_racket_id)
  where status in ('entered', 'complete');

-- ----------------------------------------------------------------------------
-- 5. Default string attributes: color and gauge.
--    (Products keep any stored material / length values; they're just no
--    longer attributes, so they aren't shown or required.)
-- ----------------------------------------------------------------------------
delete from attribute_defs a
 using categories c
 where a.category_id = c.id
   and c.name = 'Strings'
   and a.name in ('material', 'length');

-- ----------------------------------------------------------------------------
-- 6. A job's strings are specific catalog strings, with tensions.
--    Applies to writes by a signed-in user (the app, and server functions they
--    call). Writes with no signed-in user (migrations, maintenance) skip it.
-- ----------------------------------------------------------------------------

-- One side of a job: check the catalog string, lock it, check availability,
-- and return the values to copy onto the job.
create or replace function string_job_side(
  p_product_id      uuid,
  p_job_id          uuid,
  p_check_available boolean,
  p_side            text
)
returns table (brand text, name text, specs jsonb)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_product   products%rowtype;
  v_category  text;
  v_label     text;
  v_missing   text;
  v_on_hand   numeric;
  v_committed integer;
begin
  perform require_staff();

  select p.* into v_product from products p where p.id = p_product_id for update;
  if not found then
    raise exception 'Unknown string %', p_product_id;
  end if;
  select c.name into v_category from categories c where c.id = v_product.category_id;
  v_label := trim(coalesce(v_product.brand || ' ', '') || v_product.name);

  if v_category is distinct from 'Strings' then
    raise exception 'The % (%) isn''t a string', p_side, v_label;
  end if;
  if not v_product.is_active then
    raise exception '% is no longer active, so it can''t be used for a string job', v_label;
  end if;

  -- Every string attribute (color, gauge, …) must be set on the catalog string.
  select string_agg(a.name, ', ' order by a.sort_order) into v_missing
    from attribute_defs a
    join categories c on c.id = a.category_id and c.name = 'Strings'
   where coalesce(v_product.attributes->>a.name, '') = '';
  if v_missing is not null then
    raise exception '% has no % set in the catalog', v_label, v_missing;
  end if;

  select coalesce(jsonb_object_agg(a.name, v_product.attributes->a.name), '{}'::jsonb) into specs
    from attribute_defs a
    join categories c on c.id = a.category_id and c.name = 'Strings';

  if p_check_available and coalesce((select block_oversell from settings where id), false) then
    select coalesce(sum(t.qty), 0) into v_on_hand from inventory_txns t where t.product_id = p_product_id;
    select count(*) into v_committed
      from string_jobs j
     where j.status = 'entered'
       and j.id is distinct from p_job_id
       and (j.main_product_id = p_product_id or j.cross_product_id = p_product_id);
    if v_on_hand - v_committed < 1 then
      raise exception '% (%) has none available', v_label,
        (select string_agg(value, ' ' order by key) from jsonb_each_text(specs));
    end if;
  end if;

  brand := v_product.brand;
  name  := v_product.name;
  return next;
end;
$$;

revoke all on function string_job_side(uuid, uuid, boolean, text) from public, anon;
grant execute on function string_job_side(uuid, uuid, boolean, text) to authenticated;

create or replace function guard_string_job_strings()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_main        record;
  v_cross       record;
  v_check_main  boolean;
  v_check_cross boolean;
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
  return new;
end;
$$;

revoke all on function guard_string_job_strings() from public, anon, authenticated;

drop trigger if exists trg_guard_string_job_strings on string_jobs;
create trigger trg_guard_string_job_strings
  before insert or update of main_product_id, main_brand, main_string, main_specs, main_tension,
                             cross_product_id, cross_brand, cross_string, cross_specs, cross_tension
  on string_jobs
  for each row execute function guard_string_job_strings();

-- ----------------------------------------------------------------------------
-- 7. record_sale — same as 0038, plus: a string-job line has qty 1.
--    (Owner rights and search_path as set by 0040.)
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

        insert into sale_lines (sale_id, product_id, product_unit_id, qty, unit_price)
        values (v_sale_id, v_product, v_unit, v_qty, v_price);
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
        insert into sale_lines (sale_id, product_id, qty, unit_price) values (v_sale_id, v_product, v_qty, v_price);
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
      insert into sale_lines (sale_id, string_job_id, qty, unit_price) values (v_sale_id, v_job, v_qty, v_price);
      update string_jobs set paid_sale_id = v_sale_id where id = v_job;
      if v_tax_string then v_taxable := v_taxable + v_line_total; end if;

    else
      if not exists (select 1 from gift_cards where id = v_gc) then
        raise exception 'Unknown gift_card_id % in sale line', v_gc;
      end if;
      select coalesce(sum(amount), 0) into v_prev from gift_card_txns where gift_card_id = v_gc;
      insert into sale_lines (sale_id, gift_card_id, qty, unit_price) values (v_sale_id, v_gc, v_qty, v_price);
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
-- 8. Grants: signed-in staff only (as 0040/0041).
-- ----------------------------------------------------------------------------
revoke all on function advance_string_job(uuid, text)          from public, anon;
revoke all on function cancel_string_job(uuid)                 from public, anon;
revoke all on function record_sale(jsonb, uuid, jsonb, text)   from public, anon;
grant execute on function advance_string_job(uuid, text)        to authenticated;
grant execute on function cancel_string_job(uuid)               to authenticated;
grant execute on function record_sale(jsonb, uuid, jsonb, text) to authenticated;
