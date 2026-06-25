-- =============================================================================
-- 0004_create_product_design_fn.sql — atomic product-design creation
--
-- The spec-template definer writes a product_design AND its spec_attribute rows
-- AND mirrors the fields into product_design.spec_template (JSONB). That is a
-- multi-table write that must be all-or-nothing: a family with half its fields
-- corrupts the validation the whole system relies on. PostgREST can't span a
-- transaction across separate calls, so the write lives in this function — one
-- call, one transaction (a function body runs in a single implicit transaction).
--
-- Input: the family metadata + a JSON array of attribute definitions. Output:
-- the new product_design id.
--
-- SECURITY INVOKER (the default): the function runs as the calling user, so RLS
-- and the table grants from 0002/0003 still apply — no privilege escalation.
-- =============================================================================

create or replace function create_product_design(
  p_drawing_no    text,
  p_family        text,
  p_name          text,
  p_revision      integer,
  p_attributes    jsonb         -- array of { name, value_type, unit, required,
                                --            qc_gate, valid_min, valid_max, enum_values }
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_design_id     uuid := gen_random_uuid();
  v_template      jsonb := '{}'::jsonb;
  v_attr          jsonb;
  v_field         jsonb;
begin
  -- Build the spec_template JSONB mirror from the attribute array, and validate
  -- each attribute as we go.
  for v_attr in select * from jsonb_array_elements(coalesce(p_attributes, '[]'::jsonb))
  loop
    if coalesce(trim(v_attr->>'name'), '') = '' then
      raise exception 'Each spec attribute must have a non-empty name';
    end if;
    if coalesce(v_attr->>'value_type', '') not in
       ('number','text','enum','bool','ref','list') then
      raise exception 'Invalid value_type "%" for attribute "%"',
        v_attr->>'value_type', v_attr->>'name';
    end if;

    -- One field entry in the template mirror: { type, unit?, required, qc_gate,
    -- min?, max?, values? } — shaped like the data-model doc's example.
    v_field := jsonb_build_object(
      'type',     v_attr->>'value_type',
      'required', coalesce((v_attr->>'required')::boolean, false),
      'qc_gate',  coalesce((v_attr->>'qc_gate')::boolean, false)
    );
    if nullif(v_attr->>'unit', '') is not null then
      v_field := v_field || jsonb_build_object('unit', v_attr->>'unit');
    end if;
    if nullif(v_attr->>'valid_min', '') is not null then
      v_field := v_field || jsonb_build_object('min', (v_attr->>'valid_min')::numeric);
    end if;
    if nullif(v_attr->>'valid_max', '') is not null then
      v_field := v_field || jsonb_build_object('max', (v_attr->>'valid_max')::numeric);
    end if;
    if v_attr ? 'enum_values' and jsonb_typeof(v_attr->'enum_values') = 'array' then
      v_field := v_field || jsonb_build_object('values', v_attr->'enum_values');
    end if;

    v_template := v_template || jsonb_build_object(v_attr->>'name', v_field);
  end loop;

  -- Insert the design with its JSONB mirror.
  insert into product_designs (id, drawing_no, family, name, spec_template, revision)
  values (v_design_id, p_drawing_no, p_family, p_name, v_template, coalesce(p_revision, 1));

  -- Insert one spec_attribute row per field (the queryable source of truth).
  for v_attr in select * from jsonb_array_elements(coalesce(p_attributes, '[]'::jsonb))
  loop
    insert into spec_attributes (
      owner_type, owner_id, name, value_type, unit,
      required, qc_gate, valid_min, valid_max, enum_values
    )
    values (
      'product_design',
      v_design_id,
      v_attr->>'name',
      v_attr->>'value_type',
      nullif(v_attr->>'unit', ''),
      coalesce((v_attr->>'required')::boolean, false),
      coalesce((v_attr->>'qc_gate')::boolean, false),
      nullif(v_attr->>'valid_min', '')::numeric,
      nullif(v_attr->>'valid_max', '')::numeric,
      case when v_attr ? 'enum_values' and jsonb_typeof(v_attr->'enum_values') = 'array'
           then v_attr->'enum_values' else null end
    );
  end loop;

  return v_design_id;
end;
$$;

-- Allow logged-in users to call it (anon gets nothing).
grant execute on function create_product_design(text, text, text, integer, jsonb)
  to authenticated;
