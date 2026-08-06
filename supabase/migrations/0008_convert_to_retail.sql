-- =============================================================================
-- 0008_convert_to_retail.sql — CastLedger (precast) → AceStock (tennis retail)
--
-- Repurposes the project from a custom-manufacturing traceability system into a
-- general retail inventory manager for a tennis shop, with light POS.
--
-- This is a CLEAN CUTOVER on the existing Supabase project: it drops the
-- manufacturing schema (migrations 0001–0007's domain tables/functions) and
-- builds the retail schema. It KEEPS lookup_values + add_lookup_value (reused for
-- brands, colors, etc.). Migrations 0001–0007 remain in history but are
-- superseded by this file.
--
-- Retail model:
--   category          product type (Rackets, Strings, Apparel…), owns attributes
--   attribute_defs    per-category field defs; is_variant_dimension marks the
--                     attributes whose values split a product into stock variants
--   product           a sellable model: category + brand + attributes + pricing
--   variant           a stockable SKU of a product (its variant-dimension values)
--   inventory_txns    append-only stock movements (receive/adjust/sell/transfer);
--                     on-hand per variant = sum of qty
--   sales / sale_lines light POS; recording a sale posts a sell txn per line
-- =============================================================================

create extension if not exists pgcrypto;

-- =============================================================================
-- 1. DROP the manufacturing schema (order respects FK dependencies)
-- =============================================================================
drop function if exists advance_piece_status(uuid, text) cascade;
drop function if exists record_qc_test(uuid, text, numeric, text, boolean, text) cascade;
drop function if exists piece_status_rank(text) cascade;
drop function if exists create_piece(text, uuid, uuid, jsonb, numeric, text) cascade;
drop function if exists create_product_design(text, text, text, integer, jsonb) cascade;

drop table if exists qc_tests cascade;
drop table if exists inventory_txns cascade;      -- replaced by retail version below
drop table if exists pieces cascade;
drop table if exists cast_runs cascade;
drop table if exists forms cascade;
drop table if exists spec_attributes cascade;     -- replaced by attribute_defs
drop table if exists materials cascade;
drop table if exists mix_designs cascade;
drop table if exists product_designs cascade;
drop table if exists categories cascade;          -- replaced by retail categories
drop table if exists projects cascade;
drop table if exists delivery_piece cascade;
drop table if exists delivery cascade;

-- KEPT: lookup_values + add_lookup_value (reused for brands, colors, materials…).
-- Clear precast-specific lookup rows so the lists start clean for retail.
delete from lookup_values where kind in ('unit', 'field_name', 'enum_value');

-- Shared updated_at trigger fn (recreate; old tables that used it are gone).
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =============================================================================
-- 2. RETAIL SCHEMA
-- =============================================================================

-- Product categories (product types). Each owns an attribute schema.
create table categories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);
create unique index uq_categories_name on categories (name);

-- Attribute definitions per category. is_variant_dimension marks the attributes
-- whose values distinguish stock-tracked variants (e.g. grip_size, size, color).
create table attribute_defs (
  id                   uuid primary key default gen_random_uuid(),
  category_id          uuid not null references categories (id) on delete cascade,
  name                 text not null,
  value_type           text not null
                         check (value_type in ('number', 'text', 'enum', 'bool')),
  unit                 text,
  required             boolean not null default false,
  is_variant_dimension boolean not null default false,
  enum_values          jsonb,          -- for value_type = 'enum'
  sort_order           integer not null default 0,
  created_at           timestamptz not null default now()
);
create index idx_attribute_defs_category on attribute_defs (category_id);
create unique index uq_attribute_defs_cat_name on attribute_defs (category_id, name);

-- Products (sellable models). Descriptive (non-variant) attribute values live in
-- attributes JSONB; variant-defining values live on each variant.
create table products (
  id             uuid primary key default gen_random_uuid(),
  category_id    uuid not null references categories (id),
  brand          text,
  name           text not null,
  description    text,
  attributes     jsonb not null default '{}'::jsonb,
  sell_price     numeric(12, 2) check (sell_price >= 0),
  cost           numeric(12, 2) check (cost >= 0),
  reorder_point  integer check (reorder_point >= 0),
  sku            text,
  barcode        text,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index idx_products_category on products (category_id);
create index idx_products_brand on products (brand);
create unique index uq_products_sku on products (sku) where sku is not null;

create trigger trg_products_updated_at
  before update on products
  for each row execute function set_updated_at();

-- Variants: the stockable SKUs. variant_values holds the variant-dimension
-- attribute values, e.g. {"grip_size":"4 3/8"} or {"size":"10","color":"White"}.
-- A product with no variant dimensions gets exactly one "default" variant.
create table variants (
  id             uuid primary key default gen_random_uuid(),
  product_id     uuid not null references products (id) on delete cascade,
  variant_values jsonb not null default '{}'::jsonb,
  sku            text,
  barcode        text,
  sell_price     numeric(12, 2) check (sell_price >= 0),   -- overrides product price if set
  cost           numeric(12, 2) check (cost >= 0),
  reorder_point  integer check (reorder_point >= 0),
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index idx_variants_product on variants (product_id);
create unique index uq_variants_sku on variants (sku) where sku is not null;

create trigger trg_variants_updated_at
  before update on variants
  for each row execute function set_updated_at();

-- Append-only stock ledger. On-hand for a variant = sum(qty). Sign convention:
-- receipts/positive adjustments are +qty; sells/negative adjustments are -qty
-- (enforced by the app / RPCs).
create table inventory_txns (
  id            uuid primary key default gen_random_uuid(),
  txn_type      text not null
                  check (txn_type in ('receive', 'adjust', 'sell', 'transfer')),
  variant_id    uuid not null references variants (id),
  qty           numeric(14, 3) not null,        -- signed
  unit_cost     numeric(12, 2) check (unit_cost >= 0),
  location      text,
  sale_id       uuid,                            -- set for 'sell' txns (FK added below)
  note          text,
  user_id       uuid,
  created_at    timestamptz not null default now()
);
create index idx_inventory_txns_variant on inventory_txns (variant_id);
create index idx_inventory_txns_type on inventory_txns (txn_type);
create index idx_inventory_txns_sale on inventory_txns (sale_id);

-- Sales (light POS). A sale has lines; recording it posts a sell txn per line.
create table sales (
  id          uuid primary key default gen_random_uuid(),
  sold_at     timestamptz not null default now(),
  subtotal    numeric(12, 2) not null default 0 check (subtotal >= 0),
  note        text,
  user_id     uuid,
  created_at  timestamptz not null default now()
);

create table sale_lines (
  id          uuid primary key default gen_random_uuid(),
  sale_id     uuid not null references sales (id) on delete cascade,
  variant_id  uuid not null references variants (id),
  qty         integer not null check (qty > 0),
  unit_price  numeric(12, 2) not null check (unit_price >= 0),
  created_at  timestamptz not null default now()
);
create index idx_sale_lines_sale on sale_lines (sale_id);
create index idx_sale_lines_variant on sale_lines (variant_id);

-- Deferred FK: inventory_txns.sale_id -> sales.id.
alter table inventory_txns
  add constraint fk_inventory_txns_sale
  foreign key (sale_id) references sales (id);

-- Convenience view: current on-hand per variant (derived, never stored).
create view variant_stock as
select v.id as variant_id,
       coalesce(sum(t.qty), 0)::numeric as on_hand
from variants v
left join inventory_txns t on t.variant_id = v.id
group by v.id;

-- =============================================================================
-- 3. RLS + GRANTS
--   Single tenant: any authenticated shop user has full access. inventory_txns
--   is append-only (SELECT + INSERT only). RLS runs after the table privilege
--   check, so the GRANTs below are required (raw CREATE TABLE grants nothing to
--   the Supabase API roles).
-- =============================================================================
alter table categories      enable row level security;
alter table attribute_defs  enable row level security;
alter table products        enable row level security;
alter table variants        enable row level security;
alter table inventory_txns  enable row level security;
alter table sales           enable row level security;
alter table sale_lines      enable row level security;

do $$
declare
  tbl text;
  full_tables text[] := array['categories','attribute_defs','products','variants','sales','sale_lines'];
begin
  foreach tbl in array full_tables loop
    execute format(
      'create policy %I on %I for all to authenticated using (true) with check (true)',
      tbl || '_authenticated_all', tbl);
  end loop;
end;
$$;

-- Append-only ledger: SELECT + INSERT only.
create policy inventory_txns_authenticated_select
  on inventory_txns for select to authenticated using (true);
create policy inventory_txns_authenticated_insert
  on inventory_txns for insert to authenticated with check (true);

grant select, insert, update, delete on
  categories, attribute_defs, products, variants, sales, sale_lines
to authenticated;
grant select, insert on inventory_txns to authenticated;
grant select on variant_stock to authenticated;

-- Keep the ledger append-only even if a permissive policy slips in later.
revoke update, delete on inventory_txns from authenticated, anon;

-- =============================================================================
-- 4. RPCs
-- =============================================================================

-- receive_stock — post a positive receive txn for a variant. Returns txn id.
create or replace function receive_stock(
  p_variant_id uuid,
  p_qty        numeric,
  p_unit_cost  numeric,
  p_location   text,
  p_note       text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  if p_qty is null or p_qty <= 0 then
    raise exception 'Receive quantity must be positive';
  end if;
  if not exists (select 1 from variants where id = p_variant_id) then
    raise exception 'Unknown variant_id %', p_variant_id;
  end if;
  insert into inventory_txns (id, txn_type, variant_id, qty, unit_cost, location, note)
  values (v_id, 'receive', p_variant_id, p_qty, p_unit_cost, nullif(trim(p_location),''), nullif(trim(p_note),''));
  return v_id;
end;
$$;
grant execute on function receive_stock(uuid, numeric, numeric, text, text) to authenticated;

-- adjust_stock — post a signed adjustment (e.g. shrinkage, count correction).
create or replace function adjust_stock(
  p_variant_id uuid,
  p_qty        numeric,
  p_note       text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  if p_qty is null or p_qty = 0 then
    raise exception 'Adjustment quantity must be non-zero';
  end if;
  if not exists (select 1 from variants where id = p_variant_id) then
    raise exception 'Unknown variant_id %', p_variant_id;
  end if;
  insert into inventory_txns (id, txn_type, variant_id, qty, note)
  values (v_id, 'adjust', p_variant_id, p_qty, nullif(trim(p_note),''));
  return v_id;
end;
$$;
grant execute on function adjust_stock(uuid, numeric, text) to authenticated;

-- record_sale — atomic POS write: a sale header + its lines + one negative
-- 'sell' inventory_txn per line, all in one transaction (a function body runs in
-- a single implicit transaction). Input lines: [{variant_id, qty, unit_price}].
-- Returns the new sale id.
create or replace function record_sale(
  p_lines jsonb,
  p_note  text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_sale_id   uuid := gen_random_uuid();
  v_line      jsonb;
  v_variant   uuid;
  v_qty       integer;
  v_price     numeric;
  v_subtotal  numeric := 0;
begin
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'A sale needs at least one line';
  end if;

  insert into sales (id, subtotal, note) values (v_sale_id, 0, nullif(trim(p_note),''));

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_variant := (v_line->>'variant_id')::uuid;
    v_qty     := (v_line->>'qty')::integer;
    v_price   := (v_line->>'unit_price')::numeric;

    if v_variant is null or not exists (select 1 from variants where id = v_variant) then
      raise exception 'Unknown variant_id % in sale line', v_variant;
    end if;
    if v_qty is null or v_qty <= 0 then
      raise exception 'Sale line quantity must be positive';
    end if;
    if v_price is null or v_price < 0 then
      raise exception 'Sale line price must be >= 0';
    end if;

    insert into sale_lines (sale_id, variant_id, qty, unit_price)
    values (v_sale_id, v_variant, v_qty, v_price);

    -- Negative sell txn decrements on-hand.
    insert into inventory_txns (txn_type, variant_id, qty, sale_id)
    values ('sell', v_variant, -v_qty, v_sale_id);

    v_subtotal := v_subtotal + (v_qty * v_price);
  end loop;

  update sales set subtotal = v_subtotal where id = v_sale_id;
  return v_sale_id;
end;
$$;
grant execute on function record_sale(jsonb, text) to authenticated;

-- =============================================================================
-- 5. SEED — tennis shop starter data
-- =============================================================================

-- Categories
insert into categories (name, sort_order) values
  ('Rackets', 1),
  ('Strings', 2),
  ('Grips', 3),
  ('Balls', 4),
  ('Shoes', 5),
  ('Apparel', 6),
  ('Bags', 7),
  ('Accessories', 8)
on conflict (name) do nothing;

-- Attribute definitions per category. is_variant_dimension = true means the
-- attribute's value splits a product into separately-stocked variants.
-- (name, value_type, unit, required, is_variant_dimension, enum_values, sort_order)
insert into attribute_defs (category_id, name, value_type, unit, required, is_variant_dimension, enum_values, sort_order)
select c.id, a.name, a.value_type, a.unit, a.required, a.is_variant, a.enum_values, a.sort_order
from categories c
join (values
  -- Rackets
  ('Rackets','grip_size','enum',   null, true,  true,  '["4 1/8","4 1/4","4 3/8","4 1/2","4 5/8"]'::jsonb, 1),
  ('Rackets','head_size','number', 'in²',false, false, null::jsonb, 2),
  ('Rackets','weight',   'number', 'g',  false, false, null::jsonb, 3),
  ('Rackets','string_pattern','text', null, false, false, null::jsonb, 4),
  -- Strings
  ('Strings','gauge','enum', null, false, true,  '["15","15L","16","16L","17","18"]'::jsonb, 1),
  ('Strings','color','text', null, false, true,  null::jsonb, 2),
  ('Strings','material','text', null, false, false, null::jsonb, 3),
  ('Strings','length','number','ft', false, false, null::jsonb, 4),
  -- Grips
  ('Grips','type','enum', null, false, true, '["overgrip","replacement"]'::jsonb, 1),
  ('Grips','color','text', null, false, true, null::jsonb, 2),
  -- Balls
  ('Balls','type','enum', null, false, true, '["regular duty","extra duty","high altitude"]'::jsonb, 1),
  ('Balls','pack_size','number','count', false, true, null::jsonb, 2),
  -- Shoes
  ('Shoes','size','text', null, true, true, null::jsonb, 1),
  ('Shoes','width','enum', null, false, true, '["narrow","standard","wide"]'::jsonb, 2),
  ('Shoes','color','text', null, false, true, null::jsonb, 3),
  ('Shoes','gender','enum', null, false, false, '["men","women","junior","unisex"]'::jsonb, 4),
  -- Apparel
  ('Apparel','size','enum', null, true, true, '["XS","S","M","L","XL","XXL"]'::jsonb, 1),
  ('Apparel','color','text', null, false, true, null::jsonb, 2),
  ('Apparel','gender','enum', null, false, false, '["men","women","junior","unisex"]'::jsonb, 3),
  -- Bags
  ('Bags','capacity','text', null, false, true, null::jsonb, 1),
  ('Bags','color','text', null, false, true, null::jsonb, 2),
  -- Accessories
  ('Accessories','type','text', null, false, false, null::jsonb, 1)
) as a(cat, name, value_type, unit, required, is_variant, enum_values, sort_order)
  on a.cat = c.name
on conflict (category_id, name) do nothing;

-- Common tennis brands into the shared lookup (pick-or-add, kind='brand').
insert into lookup_values (kind, value) values
  ('brand','Wilson'),
  ('brand','Babolat'),
  ('brand','Head'),
  ('brand','Yonex'),
  ('brand','Prince'),
  ('brand','Dunlop'),
  ('brand','Tecnifibre'),
  ('brand','Solinco'),
  ('brand','Luxilon'),
  ('brand','Nike'),
  ('brand','Adidas'),
  ('brand','Asics')
on conflict (kind, value) do nothing;

-- Seed a few common colors too (kind='color') for the color variant fields.
insert into lookup_values (kind, value) values
  ('color','Black'),
  ('color','White'),
  ('color','Blue'),
  ('color','Red'),
  ('color','Yellow'),
  ('color','Natural')
on conflict (kind, value) do nothing;
