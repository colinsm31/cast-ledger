-- =============================================================================
-- 0055_attribute_renames.sql — renaming an attribute keeps products' values
-- (AceStock, Phase 2A)
--
-- Before:
--   • A product's attribute values are stored under the attribute's name
--     (products.attributes, e.g. {"gauge": "16"}). Editing an attribute only
--     changed its definition, so renaming one hid that value on every product
--     in the category. For Strings it also stopped string jobs, which need
--     every string attribute set on the catalog string.
--   • Renaming an enum value left products holding the old value, no longer
--     in the list.
--
-- Now:
--   update_attribute_def(...) saves an attribute and moves product values
--   with it, in one transaction:
--     • a new name moves the value to the new name on that category's
--       products only;
--     • p_value_renames ({"old": "new"}) renames enum values on those
--       products;
--     • it refuses an enum list that leaves products with a value not in it
--       (rename the value instead, or change those products first);
--     • it refuses a name some products still hold a hidden value under
--       (left over from a deleted attribute), so that value doesn't reappear.
--   It returns the number of products updated. Admins only; it runs with the
--   caller's own rights, so row-level security still applies.
--
-- Past string jobs keep the string details recorded at the time. Re-runnable.
-- =============================================================================

create or replace function update_attribute_def(
  p_id            uuid,
  p_name          text,
  p_value_type    text,
  p_unit          text,
  p_required      boolean,
  p_enum_values   jsonb,
  p_value_renames jsonb default '{}'::jsonb
)
returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_def         attribute_defs%rowtype;
  v_name        text := trim(p_name);
  v_old_values  text[] := '{}';
  v_new_values  text[];
  v_renames     jsonb := coalesce(p_value_renames, '{}'::jsonb);
  v_value       text;
  v_rename      record;
  v_stray       record;
  v_count       integer;
begin
  if not is_admin() then
    raise exception 'Only an admin can change attributes' using errcode = '42501';
  end if;

  select a.* into v_def from attribute_defs a where a.id = p_id for update;
  if not found then
    raise exception 'Unknown attribute %', p_id;
  end if;

  -- Name
  if v_name is null or v_name = '' then
    raise exception 'An attribute needs a name';
  end if;
  if exists (select 1 from attribute_defs a
              where a.category_id = v_def.category_id and a.name = v_name and a.id <> p_id) then
    raise exception 'An attribute named "%" already exists in this category', v_name;
  end if;
  if v_name <> v_def.name then
    select count(*) into v_count
      from products p
     where p.category_id = v_def.category_id and p.attributes ? v_name;
    if v_count > 0 then
      raise exception '% an old "%" value from a deleted attribute: pick another name',
        case when v_count = 1 then '1 product still holds' else v_count || ' products still hold' end, v_name;
    end if;
  end if;

  -- Type and enum values
  if p_value_type is null or p_value_type not in ('number', 'text', 'enum', 'bool') then
    raise exception 'Unknown attribute type "%"', p_value_type;
  end if;
  if v_def.value_type = 'enum' and jsonb_typeof(v_def.enum_values) = 'array' then
    select coalesce(array_agg(e), '{}') into v_old_values
      from jsonb_array_elements_text(v_def.enum_values) e;
  end if;

  if p_value_type = 'enum' then
    if p_enum_values is null or jsonb_typeof(p_enum_values) <> 'array' then
      raise exception 'An enum attribute needs at least one value';
    end if;
    if exists (select 1 from jsonb_array_elements(p_enum_values) e where jsonb_typeof(e) <> 'string') then
      raise exception 'Enum values must be text';
    end if;
    select coalesce(array_agg(trim(e) order by n), '{}') into v_new_values
      from jsonb_array_elements_text(p_enum_values) with ordinality as t(e, n);
    if cardinality(v_new_values) = 0 then
      raise exception 'An enum attribute needs at least one value';
    end if;
    if '' = any(v_new_values) then
      raise exception 'Enum values can''t be blank';
    end if;
    select e into v_value from unnest(v_new_values) e group by e having count(*) > 1 limit 1;
    if found then
      raise exception 'Enum value "%" is listed twice', v_value;
    end if;
  end if;

  -- Value renames: each from a value in the old list to a new value in the new list.
  if jsonb_typeof(v_renames) <> 'object' then
    raise exception 'Value renames must be an object of old value to new value';
  end if;
  if v_renames <> '{}'::jsonb and not (v_def.value_type = 'enum' and p_value_type = 'enum') then
    raise exception 'Only enum values can be renamed';
  end if;
  for v_rename in select key, value from jsonb_each(v_renames) loop
    if jsonb_typeof(v_rename.value) <> 'string' then
      raise exception 'Enum values must be text';
    end if;
    if not (v_rename.key = any(v_old_values)) then
      raise exception '"%" isn''t one of this attribute''s values', v_rename.key;
    end if;
    if not (v_rename.value #>> '{}' = any(v_new_values)) then
      raise exception 'Renamed value "%" must be in the new list', v_rename.value #>> '{}';
    end if;
    if v_rename.key = any(v_new_values) then
      raise exception '"%" is renamed but still in the list', v_rename.key;
    end if;
    if v_rename.value #>> '{}' = any(v_old_values) then
      raise exception '"%" is already a value: change the products using "%" first',
        v_rename.value #>> '{}', v_rename.key;
    end if;
  end loop;
  select e into v_value
    from jsonb_each_text(v_renames) as t(k, e)
   group by e having count(*) > 1 limit 1;
  if found then
    raise exception 'Two values can''t both be renamed to "%"', v_value;
  end if;

  -- An enum list must cover every value products hold (after renaming).
  if p_value_type = 'enum' then
    select coalesce(v_renames ->> (p.attributes ->> v_def.name), p.attributes ->> v_def.name) as value,
           count(*) as products
      into v_stray
      from products p
     where p.category_id = v_def.category_id
       and coalesce(p.attributes ->> v_def.name, '') <> ''
       and not (coalesce(v_renames ->> (p.attributes ->> v_def.name), p.attributes ->> v_def.name)
                = any(v_new_values))
     group by 1
     order by 2 desc, 1
     limit 1;
    if found then
      raise exception '% "%": rename it instead, or change those products first',
        case when v_stray.products = 1 then '1 product uses' else v_stray.products || ' products use' end,
        v_stray.value;
    end if;
  end if;

  -- Move product values.
  update products p
     set attributes = (p.attributes - v_def.name)
                      || jsonb_build_object(
                           v_name,
                           case when jsonb_typeof(p.attributes -> v_def.name) = 'string'
                                 and v_renames ? (p.attributes ->> v_def.name)
                                then v_renames -> (p.attributes ->> v_def.name)
                                else p.attributes -> v_def.name end)
   where p.category_id = v_def.category_id
     and p.attributes ? v_def.name
     and (v_name <> v_def.name
          or (jsonb_typeof(p.attributes -> v_def.name) = 'string'
              and v_renames ? (p.attributes ->> v_def.name)));
  get diagnostics v_count = row_count;

  update attribute_defs
     set name        = v_name,
         value_type  = p_value_type,
         unit        = nullif(trim(p_unit), ''),
         required    = coalesce(p_required, false),
         enum_values = case when p_value_type = 'enum' then to_jsonb(v_new_values) end
   where id = p_id;

  return v_count;
end;
$$;

revoke all on function update_attribute_def(uuid, text, text, text, boolean, jsonb, jsonb) from public, anon;
grant execute on function update_attribute_def(uuid, text, text, text, boolean, jsonb, jsonb) to authenticated;
