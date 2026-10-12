-- =============================================================================
-- 0045_inventory_rules.sql — unit tracking, barcodes and stock adjustments
--                            (AceStock, foundation code review #4, #16, #19, #31)
--
-- Before:
--   • Any staff member could switch a product's "track individual units" off;
--     the category's setting was only applied when the category changed. A
--     racquet switched off could be sold as ordinary stock while its units
--     stayed in stock, and so sold again by scanning a unit (#4).
--   • A code could mean two things: a unit received under a product's UPC (or
--     a racquet tag or gift card code) was found as the other thing and could
--     never be scanned, and the UPC-A and EAN-13 forms of one code could both
--     be stored and were found at random (#16).
--   • adjust_stock didn't lock the product or check a floor: "−999" worked even
--     with "block overselling" on, and could race a sale (#19).
--   • receive_stock / adjust_stock accepted unit-tracked products, whose stock
--     count ignores those entries (#31).
--
-- Now:
--   1. A product's unit tracking always comes from its category. A product
--      with stock history can't move to a category with the other setting,
--      and a category's setting can't change while its products have history.
--   2. Products: staff create and edit them; only admins delete them. Nobody
--      signed in can TRUNCATE a table (the API can't either; this closes it).
--   3. A code is used by at most one of: a product UPC, a unit barcode, an
--      active racquet tag, a gift card code — UPC-A and EAN-13 forms counting
--      as the same code. The code is locked while it's claimed, so two
--      registers can't take it at once. Barcode lookup prefers the exact form.
--   4. adjust_stock locks the product; with "block overselling" on, it can't
--      take on-hand stock below zero.
--   5. receive_stock and adjust_stock refuse unit-tracked products.
--
-- Re-runnable.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- 1. Unit tracking comes from the category.
-- ----------------------------------------------------------------------------
-- Whether a product has stock history: ledger rows, units, or sale lines.
create or replace function product_has_stock_history(p_product_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from inventory_txns where product_id = p_product_id)
      or exists (select 1 from product_units  where product_id = p_product_id)
      or exists (select 1 from sale_lines     where product_id = p_product_id);
$$;

revoke all on function product_has_stock_history(uuid) from public, anon, authenticated;

-- Replaces 0033's trigger function: applied on every insert and on any change
-- to the category or the flag, whatever the client sent.
create or replace function apply_serialized_default()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  new.is_serialized := coalesce((select c.serialized_default from categories c where c.id = new.category_id), false);

  if tg_op = 'UPDATE' and new.is_serialized <> old.is_serialized and product_has_stock_history(old.id) then
    raise exception '% has stock history, so it can''t switch to % tracking',
      trim(coalesce(old.brand || ' ', '') || old.name),
      case when new.is_serialized then 'unit' else 'counted' end;
  end if;
  return new;
end;
$$;

revoke all on function apply_serialized_default() from public, anon, authenticated;

drop trigger if exists trg_apply_serialized_default on products;
create trigger trg_apply_serialized_default
  before insert or update of category_id, is_serialized on products
  for each row execute function apply_serialized_default();

-- A category's setting: refuse a change while any of its products has
-- history; otherwise carry it to the category's products.
create or replace function guard_category_unit_tracking()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_product text;
begin
  if tg_op = 'UPDATE' and new.serialized_default is distinct from old.serialized_default then
    select trim(coalesce(p.brand || ' ', '') || p.name) into v_product
      from products p
     where p.category_id = new.id and product_has_stock_history(p.id)
     limit 1;
    if v_product is not null then
      raise exception 'Products in % have stock history (e.g. %), so its unit tracking can''t change',
        new.name, v_product;
    end if;
  end if;
  return new;
end;
$$;

create or replace function apply_category_unit_tracking()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update products set is_serialized = new.serialized_default
   where category_id = new.id and is_serialized is distinct from new.serialized_default;
  return null;
end;
$$;

revoke all on function guard_category_unit_tracking() from public, anon, authenticated;
revoke all on function apply_category_unit_tracking() from public, anon, authenticated;

drop trigger if exists trg_guard_category_unit_tracking on categories;
create trigger trg_guard_category_unit_tracking
  before update of serialized_default on categories
  for each row execute function guard_category_unit_tracking();

drop trigger if exists trg_apply_category_unit_tracking on categories;
create trigger trg_apply_category_unit_tracking
  after update of serialized_default on categories
  for each row when (new.serialized_default is distinct from old.serialized_default)
  execute function apply_category_unit_tracking();

-- ----------------------------------------------------------------------------
-- 2. Products: staff create and edit; admins delete. No TRUNCATE for clients.
-- ----------------------------------------------------------------------------
drop policy if exists products_authenticated_all on products;
drop policy if exists products_staff_select on products;
drop policy if exists products_staff_insert on products;
drop policy if exists products_staff_update on products;
drop policy if exists products_admin_delete on products;
create policy products_staff_select on products for select to authenticated using (is_staff());
create policy products_staff_insert on products for insert to authenticated with check (is_staff());
create policy products_staff_update on products for update to authenticated using (is_staff()) with check (is_staff());
create policy products_admin_delete on products for delete to authenticated using (is_admin());

do $$
declare
  t text;
begin
  -- Tables and views alike (views carry the privilege too).
  for t in select c.relname from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'f') loop
    execute format('revoke truncate on %I from authenticated, anon', t);
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 3. One code, one thing.
-- ----------------------------------------------------------------------------
-- The form codes are compared in: EAN-13 with a leading zero = UPC-A.
create or replace function barcode_canonical(p_code text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case when p_code ~ '^0[0-9]{12}$' then substr(p_code, 2) else p_code end;
$$;

-- Look-ups by that form stay fast.
create index if not exists idx_products_barcode_canon on products (barcode_canonical(barcode)) where barcode is not null;
create index if not exists idx_product_units_barcode_canon on product_units (barcode_canonical(barcode)) where barcode is not null;
create index if not exists idx_customer_rackets_barcode_canon on customer_rackets (barcode_canonical(barcode))
  where barcode is not null and is_active;
create index if not exists idx_gift_cards_code_canon on gift_cards (barcode_canonical(code));

-- What already uses this code (a description), leaving out the row being
-- written (p_table / p_id). Gift cards leave out other gift cards: their own
-- unique index covers exact repeats, and ensure_gift_card reuses a card.
create or replace function barcode_owner(p_code text, p_table text, p_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_canon text := barcode_canonical(p_code);
  v_owner text;
begin
  select 'the UPC of ' || trim(coalesce(p.brand || ' ', '') || p.name) into v_owner
    from products p
   where p.barcode is not null and barcode_canonical(p.barcode) = v_canon
     and not (p_table = 'products' and p.id = p_id)
   limit 1;
  if v_owner is not null then return v_owner; end if;

  select 'the barcode of a ' || trim(coalesce(p.brand || ' ', '') || p.name) || ' unit' into v_owner
    from product_units u join products p on p.id = u.product_id
   where u.barcode is not null and barcode_canonical(u.barcode) = v_canon
     and not (p_table = 'product_units' and u.id = p_id)
   limit 1;
  if v_owner is not null then return v_owner; end if;

  select 'the tag on ' || c.first_name || ' ' || c.last_name || '''s '
         || trim(coalesce(r.brand || ' ', '') || r.model) into v_owner
    from customer_rackets r join customers c on c.id = r.customer_id
   where r.is_active and r.barcode is not null and barcode_canonical(r.barcode) = v_canon
     and not (p_table = 'customer_rackets' and r.id = p_id)
   limit 1;
  if v_owner is not null then return v_owner; end if;

  if p_table <> 'gift_cards' then
    select 'a gift card''s code' into v_owner
      from gift_cards g
     where barcode_canonical(g.code) = v_canon
     limit 1;
  end if;
  return v_owner;
end;
$$;

-- Trigger on every table that holds a code: lock the code, then refuse it if
-- something else already uses it.
create or replace function guard_unique_barcode()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row   jsonb := to_jsonb(new);  -- the four tables name the column differently
  v_code  text;
  v_owner text;
begin
  v_code := v_row ->> case tg_table_name when 'gift_cards' then 'code' else 'barcode' end;
  if v_code is null or btrim(v_code) = '' then
    return new;
  end if;
  -- A retired racquet's tag is free to reuse.
  if tg_table_name = 'customer_rackets' and not (v_row ->> 'is_active')::boolean then
    return new;
  end if;

  -- Two registers claiming the same code wait for each other here.
  perform pg_advisory_xact_lock(hashtext('acestock.barcode:' || barcode_canonical(v_code)));

  v_owner := barcode_owner(v_code, tg_table_name, new.id);
  if v_owner is not null then
    raise exception 'Barcode % is already %', v_code, v_owner;
  end if;
  return new;
end;
$$;

revoke all on function barcode_owner(text, text, uuid) from public, anon, authenticated;
revoke all on function guard_unique_barcode() from public, anon, authenticated;
revoke all on function barcode_canonical(text) from public, anon;
grant execute on function barcode_canonical(text) to authenticated;

drop trigger if exists trg_guard_unique_barcode on products;
create trigger trg_guard_unique_barcode
  before insert or update of barcode on products
  for each row execute function guard_unique_barcode();

drop trigger if exists trg_guard_unique_barcode on product_units;
create trigger trg_guard_unique_barcode
  before insert or update of barcode on product_units
  for each row execute function guard_unique_barcode();

drop trigger if exists trg_guard_unique_barcode on customer_rackets;
create trigger trg_guard_unique_barcode
  before insert or update of barcode, is_active on customer_rackets
  for each row execute function guard_unique_barcode();

drop trigger if exists trg_guard_unique_barcode on gift_cards;
create trigger trg_guard_unique_barcode
  before insert or update of code on gift_cards
  for each row execute function guard_unique_barcode();

-- ----------------------------------------------------------------------------
-- 4 & 5. receive_stock / adjust_stock — same as 0017 (owner rights and
--        search_path per 0040), plus: refuse unit-tracked products; adjust
--        locks the product and, with "block overselling" on, can't take
--        on-hand stock below zero.
-- ----------------------------------------------------------------------------
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

create or replace function adjust_stock(p_product_id uuid, p_qty numeric, p_note text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id         uuid := gen_random_uuid();
  v_serialized boolean;
  v_name       text;
  v_on_hand    numeric;
begin
  if p_qty is null or p_qty = 0 then
    raise exception 'Adjustment quantity must be non-zero';
  end if;
  -- Lock the product, so a sale of the same item waits (and vice versa).
  select is_serialized, trim(coalesce(brand || ' ', '') || name) into v_serialized, v_name
    from products where id = p_product_id
    for update;
  if not found then
    raise exception 'Unknown product_id %', p_product_id;
  end if;
  if v_serialized then
    raise exception '% is tracked by unit; its stock is the units in stock, not an adjustable count', v_name;
  end if;

  if p_qty < 0 and coalesce((select block_oversell from settings where id), false) then
    select coalesce(sum(qty), 0) into v_on_hand from inventory_txns where product_id = p_product_id;
    if v_on_hand + p_qty < 0 then
      raise exception 'Only % of % on hand; this would take it to %',
        trim_scale(v_on_hand), v_name, trim_scale(v_on_hand + p_qty);
    end if;
  end if;

  insert into inventory_txns (id, txn_type, product_id, qty, note)
  values (v_id, 'adjust', p_product_id, p_qty, nullif(trim(p_note),''));
  return v_id;
end;
$$;

revoke all on function receive_stock(uuid, numeric, numeric, text, text) from public, anon;
revoke all on function adjust_stock(uuid, numeric, text) from public, anon;
grant execute on function receive_stock(uuid, numeric, numeric, text, text) to authenticated;
grant execute on function adjust_stock(uuid, numeric, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 6. resolve_barcode — same as 0036, plus: when both forms of a code exist
--    (from before this migration), the exact one wins.
-- ----------------------------------------------------------------------------
create or replace function resolve_barcode(p_code text)
returns table (
  kind          text,
  code          text,
  id            uuid,      -- the matched thing's id (product / unit / racket / gift card)
  product_id    uuid,      -- for a unit: its catalog product; else null
  customer_id   uuid,
  open_job_id   uuid,
  brand         text,
  name          text,
  attributes    jsonb,
  sell_price    numeric,
  is_serialized boolean,
  unit_status   text       -- for a unit: its status; else null
)
language plpgsql
security invoker
stable
set search_path = public, pg_temp
as $$
declare
  v_code       text := regexp_replace(coalesce(p_code, ''), '\s+', '', 'g');
  v_candidates text[];
  v_product    products%rowtype;
  v_unit       product_units%rowtype;
  v_racket     customer_rackets%rowtype;
  v_gift_card  gift_cards%rowtype;
begin
  if v_code = '' then
    return query select 'none', v_code, null::uuid, null::uuid, null::uuid, null::uuid,
                        null::text, null::text, null::jsonb, null::numeric, false, null::text;
    return;
  end if;

  -- EAN-13 with a leading zero <-> UPC-A.
  v_candidates := array[v_code];
  if v_code ~ '^0[0-9]{12}$' then
    v_candidates := v_candidates || substr(v_code, 2);
  elsif v_code ~ '^[0-9]{12}$' then
    v_candidates := v_candidates || ('0' || v_code);
  end if;

  -- Product UPC.
  select * into v_product from products p where p.barcode = any (v_candidates)
   order by (p.barcode = v_code) desc limit 1;
  if found then
    return query select 'product', v_product.barcode, v_product.id, null::uuid, null::uuid, null::uuid,
                        v_product.brand, v_product.name, v_product.attributes, v_product.sell_price,
                        v_product.is_serialized, null::text;
    return;
  end if;

  -- Individual unit's personal barcode.
  select * into v_unit from product_units u where u.barcode = any (v_candidates)
   order by (u.barcode = v_code) desc limit 1;
  if found then
    select * into v_product from products p where p.id = v_unit.product_id;
    return query select 'unit', v_unit.barcode, v_unit.id, v_unit.product_id, null::uuid, null::uuid,
                        v_product.brand, v_product.name, v_product.attributes, v_product.sell_price,
                        true, v_unit.status;
    return;
  end if;

  -- Customer racket tag (active rackets only).
  select * into v_racket
  from customer_rackets r
  where r.barcode = any (v_candidates) and r.is_active
  order by (r.barcode = v_code) desc
  limit 1;
  if found then
    return query select 'racket', v_racket.barcode, v_racket.id, null::uuid, v_racket.customer_id,
                        (select j.id from string_jobs j
                          where j.customer_racket_id = v_racket.id
                            and j.status in ('entered', 'complete')
                          order by j.entered_at desc limit 1),
                        null::text, null::text, null::jsonb, null::numeric, false, null::text;
    return;
  end if;

  select * into v_gift_card from gift_cards g where g.code = any (v_candidates)
   order by (g.code = v_code) desc limit 1;
  if found then
    return query select 'gift_card', v_gift_card.code, v_gift_card.id, null::uuid, v_gift_card.customer_id, null::uuid,
                        null::text, null::text, null::jsonb, null::numeric, false, null::text;
    return;
  end if;

  return query select 'none', v_code, null::uuid, null::uuid, null::uuid, null::uuid,
                      null::text, null::text, null::jsonb, null::numeric, false, null::text;
end;
$$;

revoke all on function resolve_barcode(text) from public, anon;
grant execute on function resolve_barcode(text) to authenticated;
