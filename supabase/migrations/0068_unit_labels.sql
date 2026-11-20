-- =============================================================================
-- 0068_unit_labels.sql — barcodes for frames received without one
-- (AceStock, Phase 3B)
--
-- Before:
--   • A frame could be received without a barcode ("it can be added later"),
--     but nothing could add one afterwards, so it couldn't be scanned.
--
-- Now:
--   1. assign_unit_label(unit): gives a frame with no barcode the shop's next
--      label code, "U" and a number from 10001, skipping any code already in
--      use, and returns it (or the frame's barcode, if it has one) for
--      printing. Scanning the label finds the frame like any unit barcode.
--   2. set_unit_barcode(unit, barcode): records a barcode typed or scanned
--      later for a frame that has none (at most 64 characters, no spaces).
--      A frame's barcode isn't changed once set.
--
-- Both are owner rights, staff only, and lock the frame; the barcode rules of
-- 0045 (one code, one thing) still apply. Re-runnable.
-- =============================================================================

create sequence if not exists unit_label_seq start with 10001;
revoke all on sequence unit_label_seq from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- assign_unit_label — the shop's next label code for a frame with none
-- -----------------------------------------------------------------------------
create or replace function assign_unit_label(p_unit_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_barcode text;
  v_code    text;
begin
  perform require_staff();

  select barcode into v_barcode from product_units where id = p_unit_id for update;
  if not found then
    raise exception 'Unknown unit %', p_unit_id;
  end if;
  if v_barcode is not null then
    return v_barcode;
  end if;

  loop
    v_code := 'U' || nextval('unit_label_seq');
    exit when barcode_owner(v_code, 'product_units', p_unit_id) is null;
  end loop;

  update product_units set barcode = v_code, updated_at = now() where id = p_unit_id;
  return v_code;
end;
$$;

revoke all on function assign_unit_label(uuid) from public, anon;
grant execute on function assign_unit_label(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- set_unit_barcode — a barcode added later
-- -----------------------------------------------------------------------------
create or replace function set_unit_barcode(p_unit_id uuid, p_barcode text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_code    text := btrim(coalesce(p_barcode, ''));
  v_barcode text;
begin
  perform require_staff();

  if v_code = '' then
    raise exception 'Scan or type the barcode';
  end if;
  if v_code !~ '^\S{1,64}$' then
    raise exception 'A barcode is at most 64 characters, with no spaces';
  end if;

  select barcode into v_barcode from product_units where id = p_unit_id for update;
  if not found then
    raise exception 'Unknown unit %', p_unit_id;
  end if;
  if v_barcode is not null then
    raise exception 'This frame already has barcode %', v_barcode;
  end if;

  update product_units set barcode = v_code, updated_at = now() where id = p_unit_id;
  return v_code;
end;
$$;

revoke all on function set_unit_barcode(uuid, text) from public, anon;
grant execute on function set_unit_barcode(uuid, text) to authenticated;
