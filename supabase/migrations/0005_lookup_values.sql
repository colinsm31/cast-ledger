-- =============================================================================
-- 0005_lookup_values.sql — reusable add-if-missing lookups for the editors
--
-- Repeated free-text inputs (units, field names, enum choices, …) become shared
-- vocabularies so engineers pick instead of retype, keeping values consistent
-- ("ft" not "feet"/"FT"). Each value is scoped by a `kind`. New values are added
-- inline via add_lookup_value, which is insert-if-missing (idempotent).
-- =============================================================================

create table lookup_values (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null,        -- 'unit' | 'field_name' | 'enum_value' | ...
  value       text not null,
  created_at  timestamptz not null default now()
);

-- One row per (kind, value); case-sensitive on value by design (units are).
create unique index uq_lookup_values_kind_value on lookup_values (kind, value);
create index idx_lookup_values_kind on lookup_values (kind);

-- -----------------------------------------------------------------------------
-- RLS + grants (mirrors the rest of the schema: authenticated full access)
-- -----------------------------------------------------------------------------
alter table lookup_values enable row level security;

create policy lookup_values_authenticated_all
  on lookup_values for all to authenticated using (true) with check (true);

grant select, insert, update, delete on lookup_values to authenticated;

-- -----------------------------------------------------------------------------
-- add_lookup_value — insert-if-missing, returns the canonical value.
--   Trims input; ignores blanks; safe to call repeatedly (no duplicates).
-- -----------------------------------------------------------------------------
create or replace function add_lookup_value(p_kind text, p_value text)
returns text
language plpgsql
security invoker
as $$
declare
  v_value text := trim(p_value);
begin
  if coalesce(v_value, '') = '' then
    raise exception 'Lookup value cannot be empty';
  end if;
  if coalesce(trim(p_kind), '') = '' then
    raise exception 'Lookup kind cannot be empty';
  end if;

  insert into lookup_values (kind, value)
  values (trim(p_kind), v_value)
  on conflict (kind, value) do nothing;

  return v_value;
end;
$$;

grant execute on function add_lookup_value(text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- Seed common values so the lists aren't empty on day one.
-- -----------------------------------------------------------------------------
insert into lookup_values (kind, value) values
  ('unit', 'ft'),
  ('unit', 'in'),
  ('unit', 'psi'),
  ('unit', 'lb'),
  ('unit', 'cu_yd'),
  ('unit', 'ea'),
  ('field_name', 'length_ft'),
  ('field_name', 'width_ft'),
  ('field_name', 'thickness_in'),
  ('field_name', 'target_psi'),
  ('field_name', 'water_test'),
  ('enum_value', 'required'),
  ('enum_value', 'n/a')
on conflict (kind, value) do nothing;
