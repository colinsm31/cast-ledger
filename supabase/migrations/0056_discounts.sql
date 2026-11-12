-- =============================================================================
-- 0056_discounts.sql — line and ticket discounts, with a staff limit
-- (AceStock, Phase 2B)
--
-- Before:
--   • No discounts. Charging less meant changing a line's price, which needs a
--     reason (0053), with no limit on how far staff could go.
--
-- Now:
--   1. A discount is one number, per line or for the whole ticket:
--        1        100% off
--        below 1  that fraction off (0.25 = 25% off)
--        above 1  that many dollars off each item (3 = $3 off)
--      Each needs a reason. Gift card lines can't be discounted, and the
--      ticket discount doesn't touch them.
--   2. Discounts come off each item's price, rounded to the cent, so a line's
--      unit_price is what each item finally cost and refunds and tax work as
--      before. A dollar ticket discount is spread as a share of each item's
--      price, so the total taken off can differ from the dollars entered by
--      a few cents; the quote shows the exact amount.
--   3. sale_lines keep the price before discounts and each part of the
--      discount; sales keep the ticket discount and who approved it.
--   4. settings.staff_discount_cap (percent, default 20): how far below its
--      catalog price staff can sell an item, counting price changes and
--      discounts together. Admins have no limit.
--   5. Going over the limit needs an admin's approval: approve_discount(pct),
--      called by the admin, returns a one-time approval that lasts 15 minutes
--      and covers discounts up to pct. The sale records who approved it.
--   6. discount_each(price, discount): what one discount takes off one item.
--   7. sale_totals, quote_sale and record_sale (carried over from 0053 and
--      0054) take the ticket discount and an approval; sales_summary (from
--      0054) reports discounts, and counts price changes before discounts.
--   8. Quick-pick discount reasons are seeded in lookup_values.
--
-- quote_sale, record_sale and sale_totals gain parameters, so the old
-- versions are dropped; callers passing the old arguments still work.
-- Re-runnable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3–4. Columns and settings
-- -----------------------------------------------------------------------------
alter table settings add column if not exists staff_discount_cap numeric(5, 2) not null default 20;
alter table settings drop constraint if exists ck_settings_staff_discount_cap;
alter table settings add constraint ck_settings_staff_discount_cap
  check (staff_discount_cap >= 0 and staff_discount_cap <= 100);

alter table sale_lines add column if not exists price_before_discount numeric(12, 2);
alter table sale_lines add column if not exists line_discount numeric(12, 4);
alter table sale_lines add column if not exists line_discount_each numeric(12, 2);
alter table sale_lines add column if not exists ticket_discount_each numeric(12, 2);
alter table sale_lines add column if not exists discount_reason text;
alter table sale_lines drop constraint if exists ck_sale_lines_discounts;
alter table sale_lines add constraint ck_sale_lines_discounts check (
  coalesce(line_discount_each, 0) >= 0 and coalesce(ticket_discount_each, 0) >= 0
  and (price_before_discount is null
       or price_before_discount = unit_price + coalesce(line_discount_each, 0) + coalesce(ticket_discount_each, 0)));
alter table sale_lines drop constraint if exists ck_sale_lines_discount_reason;
alter table sale_lines add constraint ck_sale_lines_discount_reason
  check (discount_reason is null or (discount_reason = trim(discount_reason) and char_length(discount_reason) between 1 and 200));

alter table sales add column if not exists ticket_discount numeric(12, 4);
alter table sales add column if not exists ticket_discount_reason text;
alter table sales add column if not exists discount_approved_by uuid references profiles (id);
alter table sales drop constraint if exists ck_sales_ticket_discount_reason;
alter table sales add constraint ck_sales_ticket_discount_reason
  check (ticket_discount_reason is null
         or (ticket_discount_reason = trim(ticket_discount_reason) and char_length(ticket_discount_reason) between 1 and 200));

comment on column settings.staff_discount_cap is 'Percent below catalog price staff can sell an item without an admin''s approval';
comment on column sale_lines.price_before_discount is 'Each item''s price before discounts; null when not discounted';
comment on column sale_lines.line_discount is 'The line discount as entered: 1 = 100%, below 1 = fraction, above 1 = dollars each';
comment on column sale_lines.line_discount_each is 'What the line discount took off each item';
comment on column sale_lines.ticket_discount_each is 'What the ticket discount took off each item';
comment on column sales.ticket_discount is 'The ticket discount as entered: 1 = 100%, below 1 = fraction, above 1 = dollars';
comment on column sales.discount_approved_by is 'The admin who approved discounts over the staff limit';

-- -----------------------------------------------------------------------------
-- 5. Approvals
-- -----------------------------------------------------------------------------
create table if not exists discount_approvals (
  id           uuid primary key default gen_random_uuid(),
  approved_by  uuid not null default auth.uid() references profiles (id),
  max_percent  numeric(5, 2) not null check (max_percent > 0 and max_percent <= 100),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '15 minutes',
  sale_id      uuid references sales (id)
);
comment on table discount_approvals is 'One-time admin approvals for discounts over the staff limit';

alter table discount_approvals enable row level security;
drop policy if exists discount_approvals_admin_select on discount_approvals;
drop policy if exists discount_approvals_admin_insert on discount_approvals;
create policy discount_approvals_admin_select on discount_approvals
  for select to authenticated using (is_admin());
create policy discount_approvals_admin_insert on discount_approvals
  for insert to authenticated with check (is_admin() and approved_by = auth.uid() and sale_id is null);
revoke all on discount_approvals from anon, authenticated;
grant select, insert on discount_approvals to authenticated;

create or replace function approve_discount(p_max_percent numeric)
returns uuid
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if not is_admin() then
    raise exception 'Only an admin can approve a discount' using errcode = '42501';
  end if;
  if p_max_percent is null or p_max_percent <= 0 or p_max_percent > 100 then
    raise exception 'Approve a discount between 0%% and 100%%';
  end if;
  insert into discount_approvals (max_percent) values (round(p_max_percent, 2)) returning id into v_id;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. discount_each — what one discount takes off one item
-- -----------------------------------------------------------------------------
create or replace function discount_each(p_price numeric, p_discount numeric)
returns numeric
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  if p_discount is null or p_discount = 0 then
    return 0;
  end if;
  if p_discount < 0 or p_discount = 'NaN' then
    raise exception 'A discount can''t be negative';
  end if;
  if p_discount = 1 then
    return p_price;
  end if;
  if p_discount < 1 then
    return round(p_price * p_discount, 2);
  end if;
  if p_discount <> round(p_discount, 2) then
    raise exception 'A dollar discount must be in whole cents';
  end if;
  if p_discount > p_price then
    raise exception 'A $% discount is more than the $% price',
      to_char(p_discount, 'FM999999990.00'), to_char(p_price, 'FM999999990.00');
  end if;
  return p_discount;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7a. sale_totals — with discounts
-- -----------------------------------------------------------------------------
-- p_ticket: { discount, discount_reason } or null.
-- Returns
--   { lines: [{ line_total, taxable, list_price, price_changed, price_reason,
--               price_before_discount, line_discount_each, ticket_discount_each,
--               unit_price, discount_reason, discount_percent }],
--     subtotal, taxable, tax_rate, tax, total,
--     discount_total, ticket_discount_reason, max_discount_percent, staff_discount_cap }
-- with lines in the same order as p_lines. price_before_discount is each
-- item's price as entered; unit_price is what each item costs after
-- discounts. discount_percent is how far unit_price is below the catalog price
-- (or the entered price when there is none). Raises for a discount that can't
-- be applied; doesn't check reasons: callers do.
drop function if exists sale_totals(jsonb);
create or replace function sale_totals(p_lines jsonb, p_ticket jsonb default null)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_rate        numeric;
  v_tax_string  boolean;
  v_cap         numeric;
  v_line        jsonb;
  v_qty         integer;
  v_price       numeric;
  v_line_each   numeric;
  v_ticket_each numeric;
  v_unit        numeric;
  v_line_total  numeric;
  v_taxed       boolean;
  v_list        numeric;
  v_changed     boolean;
  v_eligible    boolean;
  v_base        numeric;
  v_percent     numeric;
  v_ticket      numeric := nullif(nullif(p_ticket->>'discount', '')::numeric, 0);
  v_ticket_frac numeric;
  v_after_line  numeric := 0;
  v_lines       jsonb := '[]'::jsonb;
  v_subtotal    numeric := 0;
  v_taxable     numeric := 0;
  v_discounts   numeric := 0;
  v_max_percent numeric := 0;
  v_tax         numeric;
begin
  select tax_rate, tax_stringing, staff_discount_cap into v_rate, v_tax_string, v_cap from settings where id = true;
  v_rate       := coalesce(v_rate, 0);
  v_tax_string := coalesce(v_tax_string, false);

  -- What the eligible items cost after their line discounts: the base a
  -- dollar ticket discount is spread over.
  for v_line in select value from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb))
  loop
    if nullif(v_line->>'gift_card_id', '') is null then
      v_price := (v_line->>'unit_price')::numeric;
      v_after_line := v_after_line
        + (v_line->>'qty')::integer * (v_price - discount_each(v_price, nullif(v_line->>'discount', '')::numeric));
    elsif coalesce(nullif(v_line->>'discount', '')::numeric, 0) <> 0 then
      raise exception 'A gift card sale can''t be discounted';
    end if;
  end loop;

  if v_ticket is not null and v_ticket > 1 then
    if v_ticket <> round(v_ticket, 2) then
      raise exception 'A dollar discount must be in whole cents';
    end if;
    if v_ticket > v_after_line then
      raise exception 'A $% ticket discount is more than the $% of items it applies to',
        to_char(v_ticket, 'FM999999990.00'), to_char(v_after_line, 'FM999999990.00');
    end if;
    v_ticket_frac := v_ticket / v_after_line;
  elsif v_ticket is not null and v_ticket < 0 then
    raise exception 'A discount can''t be negative';
  end if;

  for v_line in select value from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) with ordinality order by ordinality
  loop
    v_qty      := (v_line->>'qty')::integer;
    v_price    := (v_line->>'unit_price')::numeric;
    v_eligible := nullif(v_line->>'gift_card_id', '') is null;
    v_line_each   := 0;
    v_ticket_each := 0;
    if v_eligible then
      v_line_each := discount_each(v_price, nullif(v_line->>'discount', '')::numeric);
      v_ticket_each := case
        when v_ticket is null then 0
        when v_ticket_frac is not null then round((v_price - v_line_each) * v_ticket_frac, 2)
        else discount_each(v_price - v_line_each, v_ticket)
      end;
    end if;
    v_unit       := v_price - v_line_each - v_ticket_each;
    v_line_total := v_qty * v_unit;
    v_taxed := case
      when nullif(v_line->>'product_id', '') is not null then true
      when nullif(v_line->>'string_job_id', '') is not null then v_tax_string
      else false
    end;
    v_list := case
      when nullif(v_line->>'product_id', '') is not null then
        (select sell_price from products where id = nullif(v_line->>'product_id', '')::uuid)
      when nullif(v_line->>'string_job_id', '') is not null then
        (select price from string_jobs where id = nullif(v_line->>'string_job_id', '')::uuid)
    end;
    v_changed := v_list is not null and v_price <> v_list;
    v_base    := coalesce(v_list, v_price);
    v_percent := case when v_base > 0 then greatest(0, round((v_base - v_unit) / v_base * 100, 2)) else 0 end;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'line_total',            v_line_total,
      'taxable',               v_taxed,
      'list_price',            v_list,
      'price_changed',         v_changed,
      'price_reason',          case when v_changed then nullif(trim(v_line->>'price_reason'), '') end,
      'price_before_discount', v_price,
      'line_discount_each',    v_line_each,
      'ticket_discount_each',  v_ticket_each,
      'unit_price',            v_unit,
      'discount_reason',       case when v_line_each > 0 then nullif(trim(v_line->>'discount_reason'), '') end,
      'discount_percent',      v_percent));
    v_subtotal    := v_subtotal + v_line_total;
    v_discounts   := v_discounts + v_qty * (v_line_each + v_ticket_each);
    v_max_percent := greatest(v_max_percent, v_percent);
    if v_taxed then v_taxable := v_taxable + v_line_total; end if;
  end loop;

  v_tax := round(v_taxable * v_rate / 100.0, 2);
  return jsonb_build_object(
    'lines',                  v_lines,
    'subtotal',               v_subtotal,
    'taxable',                v_taxable,
    'tax_rate',               v_rate,
    'tax',                    v_tax,
    'total',                  v_subtotal + v_tax,
    'discount_total',         v_discounts,
    'ticket_discount_reason', case when v_ticket is not null then nullif(trim(p_ticket->>'discount_reason'), '') end,
    'max_discount_percent',   v_max_percent,
    'staff_discount_cap',     coalesce(v_cap, 100)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 7b. require_sale_line — plus limits on the discount reason
-- -----------------------------------------------------------------------------
create or replace function require_sale_line(p_line jsonb)
returns void
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_qty   integer := (p_line->>'qty')::integer;
  v_price numeric := (p_line->>'unit_price')::numeric;
begin
  if v_qty is null or v_qty <= 0 then raise exception 'Sale line quantity must be positive'; end if;
  if v_price is null or v_price < 0 then raise exception 'Sale line price must be >= 0'; end if;
  if (case when nullif(p_line->>'product_id', '') is null then 0 else 1 end)
   + (case when nullif(p_line->>'string_job_id', '') is null then 0 else 1 end)
   + (case when nullif(p_line->>'gift_card_id', '') is null then 0 else 1 end) <> 1 then
    raise exception 'A sale line must reference exactly one of product, string job, or gift card';
  end if;
  if char_length(trim(p_line->>'price_reason')) > 200 then
    raise exception 'A price change reason can be at most 200 characters';
  end if;
  if char_length(trim(p_line->>'discount_reason')) > 200 then
    raise exception 'A discount reason can be at most 200 characters';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7c. discount_approval_problem — why discounts this far off need an approval
-- -----------------------------------------------------------------------------
-- Null when the caller is an admin, the discounts are within the staff
-- limit, or p_approval_id is an unused, unexpired approval that covers them.
-- Internal: quote_sale and record_sale call it.
create or replace function discount_approval_problem(p_totals jsonb, p_approval_id uuid)
returns text
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_max numeric := (p_totals->>'max_discount_percent')::numeric;
  v_cap numeric := (p_totals->>'staff_discount_cap')::numeric;
  v_ok  boolean;
begin
  if v_max <= v_cap or is_admin() then
    return null;
  end if;
  if p_approval_id is not null then
    select a.sale_id is null and a.expires_at > now() and a.max_percent >= v_max into v_ok
      from discount_approvals a where a.id = p_approval_id;
    if v_ok then
      return null;
    end if;
    return format('The admin approval doesn''t cover %s%% off (it may have expired or been used): ask again',
                  trim_scale(v_max));
  end if;
  return format('%s%% off is over the staff limit of %s%%: an admin must approve it',
                trim_scale(v_max), trim_scale(v_cap));
end;
$$;

-- -----------------------------------------------------------------------------
-- 7d. quote_sale — same as 0053, with discounts
-- -----------------------------------------------------------------------------
-- Ticket-wide problems (the ticket discount's reason, the staff limit) have
-- line null.
drop function if exists quote_sale(jsonb, uuid);
create or replace function quote_sale(
  p_lines       jsonb,
  p_customer_id uuid,
  p_ticket      jsonb default null,
  p_approval_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_line        jsonb;
  v_index       integer;
  v_problems    jsonb := '[]'::jsonb;
  v_problem     text;
  v_product     uuid;
  v_unit        uuid;
  v_job         uuid;
  v_gc          uuid;
  v_qty         integer;
  v_serialized  boolean;
  v_unit_status text;
  v_unit_prod   uuid;
  v_job_status  text;
  v_job_paid    uuid;
  v_block       boolean;
  v_short       record;
  v_totals      jsonb;
  v_priced      jsonb;
begin
  perform require_staff();
  perform require_cents_each(p_lines, 'unit_price', 'Price');
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'A sale needs at least one line';
  end if;
  if p_customer_id is not null
     and not exists (select 1 from customers where id = p_customer_id) then
    raise exception 'Unknown customer_id %', p_customer_id;
  end if;

  for v_line, v_index in select value, ordinality - 1 from jsonb_array_elements(p_lines) with ordinality
  loop
    perform require_sale_line(v_line);
  end loop;
  v_totals := sale_totals(p_lines, p_ticket);

  for v_line, v_index in select value, ordinality - 1 from jsonb_array_elements(p_lines) with ordinality
  loop
    v_product := nullif(v_line->>'product_id', '')::uuid;
    v_unit    := nullif(v_line->>'product_unit_id', '')::uuid;
    v_job     := nullif(v_line->>'string_job_id', '')::uuid;
    v_gc      := nullif(v_line->>'gift_card_id', '')::uuid;
    v_qty     := (v_line->>'qty')::integer;
    v_problem := null;

    if v_product is not null then
      select is_serialized into v_serialized from products where id = v_product;
      if v_serialized is null then
        v_problem := 'This item is no longer in the catalog';
      elsif v_serialized then
        select status, product_id into v_unit_status, v_unit_prod from product_units where id = v_unit;
        if v_unit is null then
          v_problem := 'This item is tracked by unit: scan the unit being sold';
        elsif v_qty <> 1 then
          v_problem := 'Items tracked by unit sell one per line';
        elsif v_unit_status is null then
          v_problem := 'This unit is no longer on file';
        elsif v_unit_prod <> v_product then
          v_problem := 'This unit belongs to a different product';
        elsif v_unit_status <> 'in_stock' then
          v_problem := format('This unit is no longer in stock (%s)', replace(v_unit_status, '_', ' '));
        end if;
      end if;

    elsif v_job is not null then
      select status, paid_sale_id into v_job_status, v_job_paid from string_jobs where id = v_job;
      if not found then
        v_problem := 'This string job is no longer on file';
      elsif v_qty <> 1 then
        v_problem := 'A string job is charged once per line';
      elsif v_job_status = 'cancelled' then
        v_problem := 'This string job was cancelled';
      elsif v_job_paid is not null then
        v_problem := 'This string job is already paid';
      elsif exists (select 1 from jsonb_array_elements(p_lines) with ordinality o(l, n)
                     where n - 1 < v_index and nullif(l->>'string_job_id', '')::uuid = v_job) then
        v_problem := 'This string job is on the ticket more than once';
      end if;

    elsif not exists (select 1 from gift_cards where id = v_gc) then
      v_problem := 'This gift card is no longer on file';
    end if;

    v_priced := v_totals->'lines'->v_index;
    if v_problem is null and (v_priced->>'price_changed')::boolean and v_priced->>'price_reason' is null then
      v_problem := format('Price changed from $%s: give a reason',
                          to_char((v_priced->>'list_price')::numeric, 'FM999999990.00'));
    end if;
    if v_problem is null and (v_priced->>'line_discount_each')::numeric > 0 and v_priced->>'discount_reason' is null then
      v_problem := 'Discount: give a reason';
    end if;

    if v_problem is not null then
      v_problems := v_problems || jsonb_build_array(jsonb_build_object('line', v_index, 'message', v_problem));
    end if;
  end loop;

  -- Overselling blocked: everything of one product on the ticket, against what's
  -- on hand, reported on that product's first line.
  select block_oversell into v_block from settings where id = true;
  if v_block then
    for v_short in
      select t.product_id, min(t.n) - 1 as first_line, sum(t.qty) as wanted,
             (select coalesce(sum(qty), 0) from inventory_txns i where i.product_id = t.product_id) as on_hand
        from (select nullif(l->>'product_id', '')::uuid as product_id, (l->>'qty')::integer as qty, n
                from jsonb_array_elements(p_lines) with ordinality o(l, n)) t
        join products p on p.id = t.product_id and not p.is_serialized
       group by t.product_id
      having sum(t.qty) > (select coalesce(sum(qty), 0) from inventory_txns i where i.product_id = t.product_id)
       order by min(t.n)
    loop
      v_problems := v_problems || jsonb_build_array(jsonb_build_object(
        'line', v_short.first_line,
        'message', format('Not enough stock: %s on hand, %s on this ticket', trim_scale(v_short.on_hand), v_short.wanted)));
    end loop;
  end if;

  -- Ticket-wide: the ticket discount's reason, and the staff limit.
  if coalesce(nullif(p_ticket->>'discount', '')::numeric, 0) <> 0 and v_totals->>'ticket_discount_reason' is null then
    v_problems := v_problems || jsonb_build_array(jsonb_build_object('line', null, 'message', 'Ticket discount: give a reason'));
  end if;
  v_problem := discount_approval_problem(v_totals, p_approval_id);
  if v_problem is not null then
    v_problems := v_problems || jsonb_build_array(jsonb_build_object('line', null, 'message', v_problem));
  end if;

  return v_totals || jsonb_build_object('problems', v_problems);
end;
$$;

-- -----------------------------------------------------------------------------
-- 7e. record_sale — same as 0054, with discounts
-- -----------------------------------------------------------------------------
drop function if exists record_sale(jsonb, uuid, jsonb, text);
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

  -- The totals, and which lines are taxed, come from sale_totals: the same
  -- function quote_sale uses, so the total the register showed before payment
  -- is the total this sale requires.
  v_totals   := sale_totals(p_lines, p_ticket);
  v_subtotal := (v_totals->>'subtotal')::numeric;
  v_tax      := (v_totals->>'tax')::numeric;
  v_rate     := (v_totals->>'tax_rate')::numeric;
  v_total    := (v_totals->>'total')::numeric;

  insert into sales (id, customer_id, subtotal, note, ticket_discount, ticket_discount_reason)
  values (v_sale_id, p_customer_id, 0, nullif(trim(p_note), ''),
          v_ticket, v_totals->>'ticket_discount_reason');

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
    if v_line_each is not null and v_disc_reason is null then
      raise exception 'The discount on line % needs a reason', v_index + 1;
    end if;
  end loop;

  -- Discounts, checked after each line's own rules: the ticket discount needs
  -- a reason, and anything over the staff limit needs an admin (signed in, or
  -- their approval, used up by this sale).
  if v_ticket is not null and v_totals->>'ticket_discount_reason' is null then
    raise exception 'The ticket discount needs a reason';
  end if;
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
-- 7f. sales_summary — same as 0054, plus discounts
-- -----------------------------------------------------------------------------
-- price_changes compares the catalog price with the price before discounts,
-- so a discount isn't also counted as a price change.
drop function if exists sales_summary(timestamptz, timestamptz);
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
  price_change_total numeric,
  discounts       integer,
  discount_total  numeric
)
language sql
stable
set search_path = public, pg_temp
as $$
  with s as (
    select id, tax, customer_id from sales where sold_at >= p_from and sold_at < p_to
  ),
  lines as (
    select sl.qty, sl.unit_price, sl.product_id, sl.gift_card_id, sl.list_price,
           coalesce(sl.price_before_discount, sl.unit_price) as price_before_discount
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
    (select count(*) from lines where list_price is not null and price_before_discount <> list_price)::int
                                                                                                as price_changes,
    coalesce((select sum(qty * (price_before_discount - list_price)) from lines
               where list_price is not null and price_before_discount <> list_price), 0)        as price_change_total,
    (select count(*) from lines where unit_price <> price_before_discount)::int                 as discounts,
    coalesce((select sum(qty * (price_before_discount - unit_price)) from lines), 0)            as discount_total
  from totals t;
$$;

-- -----------------------------------------------------------------------------
-- 8. Quick-pick reasons
-- -----------------------------------------------------------------------------
insert into lookup_values (kind, value) values
  ('discount_reason', 'Employee'),
  ('discount_reason', 'Promotion'),
  ('discount_reason', 'Damaged'),
  ('discount_reason', 'Loyalty')
on conflict (kind, value) do nothing;

revoke all on function discount_each(numeric, numeric) from public, anon, authenticated;
revoke all on function sale_totals(jsonb, jsonb) from public, anon, authenticated;
revoke all on function require_sale_line(jsonb) from public, anon, authenticated;
revoke all on function discount_approval_problem(jsonb, uuid) from public, anon, authenticated;
revoke all on function approve_discount(numeric) from public, anon;
revoke all on function quote_sale(jsonb, uuid, jsonb, uuid) from public, anon;
revoke all on function record_sale(jsonb, uuid, jsonb, text, jsonb, uuid) from public, anon;
revoke all on function sales_summary(timestamptz, timestamptz) from public, anon;
grant execute on function approve_discount(numeric) to authenticated;
grant execute on function quote_sale(jsonb, uuid, jsonb, uuid) to authenticated;
grant execute on function record_sale(jsonb, uuid, jsonb, text, jsonb, uuid) to authenticated;
grant execute on function sales_summary(timestamptz, timestamptz) to authenticated;
