-- =============================================================================
-- 0006_create_piece_fn.sql — create a piece instance from a design
--
-- The piece clone-and-edit editor saves a single piece: universal fields plus
-- its spec_values JSONB (validated in-app against the template). This is a
-- single-row insert, but it lives in a function so the server can pin the
-- as-poured design revision from the design itself (not trust the client) and
-- to keep one clean entry point for piece creation.
--
-- SECURITY INVOKER: runs as the caller, so RLS + grants still apply.
-- =============================================================================

create or replace function create_piece(
  p_mark_no            text,
  p_product_design_id  uuid,
  p_project_id         uuid,
  p_spec_values        jsonb,
  p_weight_lb          numeric,
  p_yard_location      text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_piece_id   uuid := gen_random_uuid();
  v_revision   integer;
begin
  if coalesce(trim(p_mark_no), '') = '' then
    raise exception 'Mark number is required';
  end if;

  -- Pin the design revision from the design row (server-authoritative).
  select revision into v_revision
  from product_designs
  where id = p_product_design_id;

  if v_revision is null then
    raise exception 'Unknown product_design_id %', p_product_design_id;
  end if;

  insert into pieces (
    id, mark_no, project_id, product_design_id, product_design_revision,
    spec_values, weight_lb, status, yard_location
  )
  values (
    v_piece_id,
    trim(p_mark_no),
    p_project_id,
    p_product_design_id,
    v_revision,
    coalesce(p_spec_values, '{}'::jsonb),
    p_weight_lb,
    'in_production',                 -- lifecycle starts here
    nullif(trim(p_yard_location), '')
  );

  return v_piece_id;
end;
$$;

grant execute on function
  create_piece(text, uuid, uuid, jsonb, numeric, text)
  to authenticated;
