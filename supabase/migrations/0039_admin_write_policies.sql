-- =============================================================================
-- 0039_admin_write_policies.sql — admin-only shop configuration (AceStock, 1C)
--
-- Settings, categories and attribute definitions were writable by every
-- signed-in user; only the web app's screens kept staff out. The database now
-- enforces it: everyone signed in can read them, only admins (is_admin()) can
-- change them. A staff account calling the API directly gets an error on
-- insert and changes nothing on update/delete.
--
-- Roles were already protected (profiles is read-only to clients; role changes
-- go through set_user_role, which checks is_admin()).
--
-- Re-runnable.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- 1. settings (single row): read for all, update for admins only.
-- ----------------------------------------------------------------------------
drop policy if exists settings_authenticated_update on settings;
drop policy if exists settings_admin_update on settings;
create policy settings_admin_update on settings
  for update to authenticated
  using (is_admin())
  with check (is_admin());

-- ----------------------------------------------------------------------------
-- 2. categories and attribute_defs: read for all, write for admins only.
-- ----------------------------------------------------------------------------
do $$
declare
  tbl text;
begin
  foreach tbl in array array['categories', 'attribute_defs'] loop
    execute format('drop policy if exists %I on %I', tbl || '_authenticated_all', tbl);
    execute format('drop policy if exists %I on %I', tbl || '_authenticated_select', tbl);
    execute format('drop policy if exists %I on %I', tbl || '_admin_insert', tbl);
    execute format('drop policy if exists %I on %I', tbl || '_admin_update', tbl);
    execute format('drop policy if exists %I on %I', tbl || '_admin_delete', tbl);

    execute format(
      'create policy %I on %I for select to authenticated using (true)',
      tbl || '_authenticated_select', tbl);
    execute format(
      'create policy %I on %I for insert to authenticated with check (is_admin())',
      tbl || '_admin_insert', tbl);
    execute format(
      'create policy %I on %I for update to authenticated using (is_admin()) with check (is_admin())',
      tbl || '_admin_update', tbl);
    execute format(
      'create policy %I on %I for delete to authenticated using (is_admin())',
      tbl || '_admin_delete', tbl);
  end loop;
end $$;
