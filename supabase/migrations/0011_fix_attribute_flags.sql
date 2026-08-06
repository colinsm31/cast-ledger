-- =============================================================================
-- 0011_fix_attribute_flags.sql — repair attribute_defs to the canonical set
--
-- Symptom this fixes: every variant shows "Default" and the add-item form shows
-- no dimension fields — because the live attribute_defs are missing the
-- is_variant_dimension flags (0008's seed used ON CONFLICT DO NOTHING, so if
-- rows already existed with wrong flags they were never corrected).
--
-- This re-asserts the canonical tennis attribute definitions with an UPSERT that
-- UPDATES existing rows (unlike the original DO NOTHING). Idempotent and safe to
-- run on a correct database (it's a no-op there).
--
-- NOTE: this overwrites attribute_defs to the standard set. If you've customized
-- attribute definitions by hand, review before running.
-- =============================================================================

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
on conflict (category_id, name) do update
  set value_type           = excluded.value_type,
      unit                 = excluded.unit,
      required             = excluded.required,
      is_variant_dimension = excluded.is_variant_dimension,
      enum_values          = excluded.enum_values,
      sort_order           = excluded.sort_order;
