-- =============================================================================
-- 0007_qc_and_lifecycle_fns.sql — QC capture + manual lifecycle advancement
--
-- Two RPCs:
--   record_qc_test       — append-only insert into qc_tests (one clean entry point)
--   advance_piece_status — manual, one legal forward step at a time, with the QC
--                          gate enforced server-side when leaving 'qc'.
--
-- QC gate (to advance out of 'qc'): the piece must have
--   (a) at least one PASSING qc_test, AND
--   (b) every qc_gate spec field its design declares present (non-null) in the
--       piece's spec_values.
-- Enforcing this in the DB (not just the UI) means the invariant can't be
-- bypassed and both clients get it for free.
--
-- SECURITY INVOKER: runs as the caller, so RLS + grants still apply.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- record_qc_test — append-only QC test insert. Returns the new test id.
-- -----------------------------------------------------------------------------
create or replace function record_qc_test(
  p_piece_id   uuid,
  p_test_type  text,
  p_value      numeric,
  p_unit       text,
  p_pass       boolean,
  p_tested_by  text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_test_id uuid := gen_random_uuid();
begin
  if p_piece_id is null then
    raise exception 'piece_id is required';
  end if;
  if not exists (select 1 from pieces where id = p_piece_id) then
    raise exception 'Unknown piece_id %', p_piece_id;
  end if;
  if coalesce(p_test_type, '') not in ('break_7day','break_28day','water_test','other') then
    raise exception 'Invalid test_type "%"', p_test_type;
  end if;

  insert into qc_tests (id, piece_id, test_type, value, unit, pass, tested_by)
  values (v_test_id, p_piece_id, p_test_type, p_value, nullif(trim(p_unit), ''),
          p_pass, nullif(trim(p_tested_by), ''));

  return v_test_id;
end;
$$;

grant execute on function
  record_qc_test(uuid, text, numeric, text, boolean, text)
  to authenticated;

-- -----------------------------------------------------------------------------
-- Lifecycle order helper — index of a status in the forward sequence.
-- -----------------------------------------------------------------------------
create or replace function piece_status_rank(p_status text)
returns integer
language sql
immutable
as $$
  select case p_status
    when 'in_production' then 0
    when 'curing'        then 1
    when 'qc'            then 2
    when 'ready'         then 3
    when 'staged'        then 4
    when 'delivered'     then 5
    else -1
  end;
$$;

-- -----------------------------------------------------------------------------
-- advance_piece_status — move a piece exactly one legal step forward.
--   Rejects skips and backward moves. Enforces the QC gate when leaving 'qc'.
--   Returns the new status.
-- -----------------------------------------------------------------------------
create or replace function advance_piece_status(
  p_piece_id      uuid,
  p_target_status text
)
returns text
language plpgsql
security invoker
as $$
declare
  v_current        text;
  v_design_id      uuid;
  v_current_rank   integer;
  v_target_rank    integer;
  v_passing_tests  integer;
  v_unmet_gate     text;
begin
  select status, product_design_id
    into v_current, v_design_id
  from pieces
  where id = p_piece_id;

  if v_current is null then
    raise exception 'Unknown piece_id %', p_piece_id;
  end if;

  v_current_rank := piece_status_rank(v_current);
  v_target_rank  := piece_status_rank(p_target_status);

  if v_target_rank < 0 then
    raise exception 'Invalid target status "%"', p_target_status;
  end if;

  -- Exactly one step forward (no skipping, no going back).
  if v_target_rank <> v_current_rank + 1 then
    raise exception 'Cannot move from "%" to "%": only one step forward is allowed',
      v_current, p_target_status;
  end if;

  -- QC gate: enforced when leaving 'qc' (i.e. qc -> ready).
  if v_current = 'qc' then
    -- (a) at least one passing QC test
    select count(*) into v_passing_tests
    from qc_tests
    where piece_id = p_piece_id and pass is true;

    if v_passing_tests = 0 then
      raise exception 'QC gate: at least one passing QC test is required before "ready"';
    end if;

    -- (b) every qc_gate spec field its design declares is present (non-null)
    --     in the piece's spec_values.
    select sa.name into v_unmet_gate
    from spec_attributes sa
    join pieces p on p.id = p_piece_id
    where sa.owner_type = 'product_design'
      and sa.owner_id = v_design_id
      and sa.qc_gate is true
      and (
        not (p.spec_values ? sa.name)
        or p.spec_values -> sa.name = 'null'::jsonb
      )
    limit 1;

    if v_unmet_gate is not null then
      raise exception 'QC gate: spec field "%" must be set before "ready"', v_unmet_gate;
    end if;
  end if;

  update pieces
    set status = p_target_status
  where id = p_piece_id;

  return p_target_status;
end;
$$;

grant execute on function
  advance_piece_status(uuid, text)
  to authenticated;
