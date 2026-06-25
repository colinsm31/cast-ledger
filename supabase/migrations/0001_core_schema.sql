-- =============================================================================
-- 0001_core_schema.sql — Waskey IPM Phase 0 core schema
--
-- Template/instance model with structured-flexible specs (JSONB), append-only
-- ledgers for raw materials and QC, and revision pinning so the as-poured truth
-- survives later design changes.
--
-- Conventions: snake_case, plural tables, PK `id uuid`. `<singular>_id` only for
-- real foreign keys. Closed sets use a domain noun / `_type` with a CHECK, never
-- `_id`. All UUIDs are client-generatable (default gen_random_uuid() server-side).
-- =============================================================================

-- gen_random_uuid() lives in pgcrypto (preinstalled on Supabase; safe to ensure).
create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- Shared: updated_at trigger (DRY — one function, reused on every mutable table)
-- -----------------------------------------------------------------------------
create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =============================================================================
-- PROJECTS
-- =============================================================================
create table projects (
  id          uuid primary key default gen_random_uuid(),
  job_number  text not null,
  name        text not null,
  client      text,
  location    text,
  status      text not null default 'active'
                check (status in ('active', 'closed', 'on_hold')),
  is_stock    boolean not null default false,   -- synthetic make-to-stock project
  created_at  timestamptz not null default now()
);
create unique index uq_projects_job_number on projects (job_number);

-- =============================================================================
-- PRODUCT DESIGNS  (the 60-year drawing catalog = reusable templates)
--   spec_template declares a family's fields/types/units/validation/QC gates.
-- =============================================================================
create table product_designs (
  id                  uuid primary key default gen_random_uuid(),
  drawing_no          text not null,
  family              text not null,            -- e.g. "Platform Deck Panel"
  name                text not null,
  base_specs          jsonb not null default '{}'::jsonb,
  spec_template       jsonb not null default '{}'::jsonb,
  default_components   jsonb not null default '[]'::jsonb,
  revision            integer not null default 1 check (revision >= 1),
  superseded_by_id    uuid references product_designs (id),
  created_at          timestamptz not null default now()
);
create unique index uq_product_designs_drawing_rev
  on product_designs (drawing_no, revision);
create index idx_product_designs_family on product_designs (family);

-- =============================================================================
-- MIX DESIGNS  (concrete recipe: both a spec and a bill of materials)
-- =============================================================================
create table mix_designs (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  target_psi  integer check (target_psi > 0),
  slump_in    numeric(5, 2) check (slump_in >= 0),
  recipe      jsonb not null default '[]'::jsonb,  -- [{material_id, qty, unit}] per cu yd
  created_at  timestamptz not null default now()
);
create unique index uq_mix_designs_name on mix_designs (name);

-- =============================================================================
-- CATEGORIES  (Rebar, Embeds, Admixture, Cement, ...)
-- =============================================================================
create table categories (
  id    uuid primary key default gen_random_uuid(),
  name  text not null
);
create unique index uq_categories_name on categories (name);

-- =============================================================================
-- SPEC ATTRIBUTES  (field definitions owned by a product_design family OR a
--   material category). Spec *values* live as JSONB on the instance.
-- =============================================================================
create table spec_attributes (
  id           uuid primary key default gen_random_uuid(),
  owner_type   text not null check (owner_type in ('category', 'product_design')),
  owner_id     uuid not null,            -- polymorphic; validated in-app per owner_type
  name         text not null,
  value_type   text not null
                 check (value_type in ('number', 'text', 'enum', 'bool', 'ref', 'list')),
  unit         text,                     -- "ft" | "in" | "psi" | "lb" | ... (nullable)
  required     boolean not null default false,
  qc_gate      boolean not null default false,
  valid_min    numeric,
  valid_max    numeric,
  enum_values   jsonb,                    -- for value_type = 'enum'
  created_at   timestamptz not null default now()
);
create index idx_spec_attributes_owner on spec_attributes (owner_type, owner_id);
create unique index uq_spec_attributes_owner_name
  on spec_attributes (owner_type, owner_id, name);

-- =============================================================================
-- MATERIALS  (raw-material catalog; spec_values JSONB per its category template)
-- =============================================================================
create table materials (
  id            uuid primary key default gen_random_uuid(),
  category_id   uuid not null references categories (id),
  description   text not null,
  default_uom   text not null,           -- unit of measure: lb, ea, ft, cu_yd, ...
  default_cost  numeric(12, 4) check (default_cost >= 0),
  spec_values   jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);
create index idx_materials_category on materials (category_id);

-- =============================================================================
-- FORMS  (reusable molds; wear tracked via use_count)
-- =============================================================================
create table forms (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  product_design_id   uuid references product_designs (id),
  location            text,
  condition           text not null default 'good'
                        check (condition in ('good', 'worn', 'needs_repair', 'retired')),
  use_count           integer not null default 0 check (use_count >= 0),
  current_cast_run_id uuid,              -- FK added after cast_runs exists (below)
  created_at          timestamptz not null default now()
);
create unique index uq_forms_name on forms (name);

-- =============================================================================
-- CAST RUNS  (one pour: consumes materials per a mix, in a form, yields pieces.
--   Snapshots the design revision actually poured — pins the as-poured truth.)
-- =============================================================================
create table cast_runs (
  id                       uuid primary key default gen_random_uuid(),
  cast_date                date not null default current_date,
  product_design_id        uuid not null references product_designs (id),
  product_design_revision  integer not null check (product_design_revision >= 1),
  mix_design_id            uuid references mix_designs (id),
  form_id                  uuid references forms (id),
  batch_no                 text not null,
  qty                      integer not null default 1 check (qty >= 1),
  labor_hours              numeric(8, 2) check (labor_hours >= 0),
  created_at               timestamptz not null default now()
);
create index idx_cast_runs_design on cast_runs (product_design_id);
create index idx_cast_runs_batch_no on cast_runs (batch_no);

-- Deferred FK: forms.current_cast_run_id -> cast_runs.id (circular dependency).
alter table forms
  add constraint fk_forms_current_cast_run
  foreign key (current_cast_run_id) references cast_runs (id);

-- =============================================================================
-- PIECES  (serialized instances — the heart of the system. NEVER a SKU.)
--   spec_values + as_built_components are per-piece JSONB; revision pins the
--   design version actually cast.
-- =============================================================================
create table pieces (
  id                       uuid primary key default gen_random_uuid(),
  mark_no                  text not null,
  project_id               uuid references projects (id),
  product_design_id        uuid not null references product_designs (id),
  product_design_revision  integer not null check (product_design_revision >= 1),
  cast_run_id              uuid references cast_runs (id),
  spec_values              jsonb not null default '{}'::jsonb,
  as_built_components      jsonb not null default '[]'::jsonb,
  weight_lb                numeric(12, 2) check (weight_lb >= 0),
  status                   text not null default 'in_production'
                             check (status in (
                               'in_production', 'curing', 'qc',
                               'ready', 'staged', 'delivered'
                             )),
  yard_location            text,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
create unique index uq_pieces_mark_no on pieces (mark_no);
create index idx_pieces_project on pieces (project_id);
create index idx_pieces_status on pieces (status);
create index idx_pieces_yard_location on pieces (yard_location);
create index idx_pieces_cast_run on pieces (cast_run_id);

create trigger trg_pieces_updated_at
  before update on pieces
  for each row execute function set_updated_at();

-- =============================================================================
-- QC TESTS  (APPEND ONLY — bound to the piece/batch revision actually poured)
-- =============================================================================
create table qc_tests (
  id          uuid primary key default gen_random_uuid(),
  piece_id    uuid references pieces (id),
  batch_no    text,                       -- batch-level tests (cylinders) may not pin a piece
  test_type   text not null
                check (test_type in (
                  'break_7day', 'break_28day', 'water_test', 'other'
                )),
  value       numeric,
  unit        text,
  pass        boolean,
  tested_at   timestamptz not null default now(),
  tested_by   text,
  -- At least one of piece_id / batch_no must identify what was tested.
  constraint chk_qc_tests_target check (piece_id is not null or batch_no is not null)
);
create index idx_qc_tests_piece on qc_tests (piece_id);
create index idx_qc_tests_batch_no on qc_tests (batch_no);

-- =============================================================================
-- INVENTORY TXN  (APPEND ONLY ledger — on-hand is summed from this, never stored)
-- =============================================================================
create table inventory_txns (
  id            uuid primary key default gen_random_uuid(),
  txn_type      text not null
                  check (txn_type in ('receipt', 'issue_to_cast_run', 'transfer', 'adjust')),
  material_id   uuid not null references materials (id),
  qty           numeric(14, 4) not null,    -- signed by convention per txn_type (app-enforced)
  unit_cost     numeric(12, 4) check (unit_cost >= 0),
  from_location text,
  to_location   text,
  cast_run_id   uuid references cast_runs (id),
  project_id    uuid references projects (id),
  user_id       uuid,                       -- the actor; from auth.uid() on the client
  created_at    timestamptz not null default now()
);
create index idx_inventory_txns_material on inventory_txns (material_id);
create index idx_inventory_txns_cast_run on inventory_txns (cast_run_id);
create index idx_inventory_txns_project on inventory_txns (project_id);
create index idx_inventory_txns_type on inventory_txns (txn_type);

-- =============================================================================
-- Notes
--  * Balances (material on-hand), job material cost, and "pieces available" are
--    DERIVED by summing inventory_txns / filtering pieces — never stored as
--    mutable columns. See data-model.md §4.
--  * Spec validation (required fields, ranges, qc_gate enforcement before status
--    advances past 'qc') runs in-app for v1, not as DB CHECK constraints — easier
--    to iterate; hot rules can move into the DB later.
-- =============================================================================
