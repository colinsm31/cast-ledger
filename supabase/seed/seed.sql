-- =============================================================================
-- seed.sql — Waskey reference data (single tenant; hardcode Waskey's reality)
--
-- Material categories, yard-location-bearing example data, a synthetic STOCK
-- project, one mix design, and one product_design template (Platform Deck Panel)
-- with its spec_attribute field definitions — enough to exercise the
-- template/instance loop. Idempotent via ON CONFLICT on natural keys.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Material categories
-- -----------------------------------------------------------------------------
insert into categories (name) values
  ('Cement'),
  ('Aggregate'),
  ('Admixture'),
  ('Rebar'),
  ('Embeds'),
  ('Insulation')
on conflict (name) do nothing;

-- -----------------------------------------------------------------------------
-- Synthetic STOCK project (make-to-stock pieces attach here; later phase)
-- -----------------------------------------------------------------------------
insert into projects (job_number, name, client, location, status, is_stock) values
  ('STOCK', 'Make-to-Stock', 'Waskey Bridges, Inc.', 'Baton Rouge, LA', 'active', true)
on conflict (job_number) do nothing;

-- A representative live job, for read-view testing.
insert into projects (job_number, name, client, location, status, is_stock) values
  ('EVG-2026', 'Entergy Evergreen Platform', 'Entergy', 'Evergreen, LA', 'active', false)
on conflict (job_number) do nothing;

-- -----------------------------------------------------------------------------
-- Mix design
-- -----------------------------------------------------------------------------
insert into mix_designs (name, target_psi, slump_in, recipe) values
  ('LW-STRUCT-5000', 5000, 5.00, '[]'::jsonb)
on conflict (name) do nothing;

-- -----------------------------------------------------------------------------
-- Product design template — "Platform Deck Panel" family, drawing WP-DECK-STD r1
-- spec_template declares the family's fields; spec_attributes hold the same
-- definitions in queryable rows (validation/QC-gate enforcement reads these).
-- -----------------------------------------------------------------------------
insert into product_designs (drawing_no, family, name, base_specs, spec_template, default_components, revision)
values (
  'WP-DECK-STD',
  'Platform Deck Panel',
  'Standard Platform Deck Panel',
  '{}'::jsonb,
  '{
    "length_ft":    { "type": "number", "unit": "ft",  "required": true, "min": 4, "max": 60 },
    "width_ft":     { "type": "number", "unit": "ft",  "required": true },
    "thickness_in": { "type": "number", "unit": "in",  "required": true },
    "mix_design":   { "type": "ref", "to": "mix_design", "required": true },
    "target_psi":   { "type": "number", "unit": "psi", "required": true },
    "water_test":   { "type": "enum", "values": ["required","n/a"], "qc_gate": true },
    "embeds":       { "type": "list", "of": "component" }
  }'::jsonb,
  '[{ "material": "rebar_#6_grade60", "qty_ft": 280 }]'::jsonb,
  1
)
on conflict (drawing_no, revision) do nothing;

-- spec_attribute rows for the Platform Deck Panel design (queryable definitions).
insert into spec_attributes (owner_type, owner_id, name, value_type, unit, required, qc_gate, valid_min, valid_max, enum_values)
select 'product_design', pd.id, a.name, a.value_type, a.unit, a.required, a.qc_gate, a.valid_min, a.valid_max, a.enum_values
from product_designs pd
cross join (values
  ('length_ft',    'number', 'ft',  true,  false, 4::numeric,    60::numeric, null::jsonb),
  ('width_ft',     'number', 'ft',  true,  false, null::numeric, null::numeric, null::jsonb),
  ('thickness_in', 'number', 'in',  true,  false, null::numeric, null::numeric, null::jsonb),
  ('target_psi',   'number', 'psi', true,  false, null::numeric, null::numeric, null::jsonb),
  ('water_test',   'enum',   null,  false, true,  null::numeric, null::numeric, '["required","n/a"]'::jsonb)
) as a(name, value_type, unit, required, qc_gate, valid_min, valid_max, enum_values)
where pd.drawing_no = 'WP-DECK-STD' and pd.revision = 1
on conflict (owner_type, owner_id, name) do nothing;
