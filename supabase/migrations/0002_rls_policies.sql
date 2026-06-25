-- =============================================================================
-- 0002_rls_policies.sql — Row-level security + append-only enforcement
--
-- Single-tenant model: any authenticated Waskey user may read/write the
-- operational tables. The append-only ledgers (inventory_txns, qc_tests) grant
-- INSERT + SELECT only — no UPDATE/DELETE — so corrections are new rows and the
-- audit trail can never drift. This is the DB-side guarantee behind the
-- traceability clients pay for.
--
-- Targets Supabase: references the `authenticated` role and auth.uid(). On a
-- plain Postgres without the Supabase auth schema, this file will error on those
-- references — apply 0001 + seed there, and this file against a Supabase target.
-- =============================================================================

-- Enable RLS on every table. With RLS on and no permissive policy, access is
-- denied by default — so each table below gets explicit policies.
alter table projects         enable row level security;
alter table product_designs  enable row level security;
alter table mix_designs      enable row level security;
alter table categories       enable row level security;
alter table spec_attributes  enable row level security;
alter table materials        enable row level security;
alter table forms            enable row level security;
alter table cast_runs        enable row level security;
alter table pieces           enable row level security;
alter table qc_tests         enable row level security;
alter table inventory_txns   enable row level security;

-- -----------------------------------------------------------------------------
-- Full-access tables (single tenant): authenticated users get full CRUD.
-- One FOR ALL policy per table, USING + WITH CHECK = authenticated.
-- -----------------------------------------------------------------------------
do $$
declare
  tbl text;
  full_access_tables text[] := array[
    'projects', 'product_designs', 'mix_designs', 'categories',
    'spec_attributes', 'materials', 'forms', 'cast_runs', 'pieces'
  ];
begin
  foreach tbl in array full_access_tables loop
    execute format(
      'create policy %I on %I for all to authenticated using (true) with check (true)',
      tbl || '_authenticated_all', tbl
    );
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Append-only ledgers: INSERT + SELECT only. No UPDATE, no DELETE policy is
-- created, so with RLS enabled those operations are denied for all non-superuser
-- roles. Corrections are new rows (an `adjust` txn, a new qc_test), never edits.
-- -----------------------------------------------------------------------------

-- inventory_txns
create policy inventory_txns_authenticated_select
  on inventory_txns for select to authenticated using (true);
create policy inventory_txns_authenticated_insert
  on inventory_txns for insert to authenticated with check (true);

-- qc_tests
create policy qc_tests_authenticated_select
  on qc_tests for select to authenticated using (true);
create policy qc_tests_authenticated_insert
  on qc_tests for insert to authenticated with check (true);

-- =============================================================================
-- Table privileges (GRANTs)
--
-- RLS policies only take effect AFTER the role passes the table-level privilege
-- check. Tables created via raw `CREATE TABLE` (e.g. the SQL editor) grant
-- nothing to the Supabase API roles, so without these GRANTs every query fails
-- with "permission denied" before RLS even runs. Grant the API role the verbs
-- its policies allow; RLS then scopes the rows.
--
-- `authenticated` = a logged-in user (what the app uses). `anon` is intentionally
-- granted nothing here — unauthenticated clients get no access.
-- =============================================================================

-- Full-access tables: authenticated may read and write.
grant select, insert, update, delete on
  projects, product_designs, mix_designs, categories,
  spec_attributes, materials, forms, cast_runs, pieces
to authenticated;

-- Append-only ledgers: authenticated may read and insert only.
grant select, insert on inventory_txns, qc_tests to authenticated;

-- =============================================================================
-- Defense in depth: revoke UPDATE/DELETE on the ledgers from the API roles so
-- the append-only invariant holds even if a future permissive policy slips in.
-- =============================================================================
revoke update, delete on inventory_txns from authenticated, anon;
revoke update, delete on qc_tests       from authenticated, anon;
