-- =============================================================================
-- 0003_grants.sql — table privileges for the Supabase API roles
--
-- Standalone, re-runnable. Apply this if 0002 was run BEFORE the GRANT block was
-- added to it (grants are idempotent, so running this is always safe). Without
-- these, a signed-in user's queries fail with "permission denied" because RLS
-- only runs after the table-level privilege check passes.
-- =============================================================================

-- Full-access tables: authenticated may read and write.
grant select, insert, update, delete on
  projects, product_designs, mix_designs, categories,
  spec_attributes, materials, forms, cast_runs, pieces
to authenticated;

-- Append-only ledgers: authenticated may read and insert only.
grant select, insert on inventory_txns, qc_tests to authenticated;

-- Keep the append-only invariant even if a permissive policy is added later.
revoke update, delete on inventory_txns from authenticated, anon;
revoke update, delete on qc_tests       from authenticated, anon;
