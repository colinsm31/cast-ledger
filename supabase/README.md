# Supabase backend

Phase 0 schema for Waskey IPM. Postgres (via Supabase): relational core + JSONB for
flexible specs, with append-only ledgers for materials and QC.

## Files

| File | Purpose |
|------|---------|
| `migrations/0001_core_schema.sql` | Core tables, constraints, indexes, the `updated_at` trigger |
| `migrations/0002_rls_policies.sql` | Enables RLS on every table; single-tenant authenticated policies; append-only enforcement on `inventory_txn` and `qc_test` |
| `seed/seed.sql` | Waskey product families, material categories, yard locations, a sample mix + design template |

Migrations are ordered by filename prefix and are **additive**. Per the migration
discipline we follow, schema changes go expand → backfill → switch → contract across
separate migrations; never an in-place rename/drop alongside dependent code.

## Apply locally with the Supabase CLI (recommended)

```bash
supabase start          # boots local Postgres + the stack
supabase db reset       # applies migrations/ in order, then seed/seed.sql
```

## Apply with plain psql (any Postgres)

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/0001_core_schema.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/0002_rls_policies.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f seed/seed.sql
```

> The RLS policies reference Supabase's `auth.uid()` and the `authenticated` role. On a
> plain Postgres without the Supabase auth schema, `0002` will error on those references —
> that file is meant for a Supabase target. The core schema (`0001`) and seed apply
> anywhere.

## Conventions

- snake_case identifiers; plural tables; PK `id uuid` (client-generatable).
- `<singular>_id` only for real foreign keys. Closed sets use a domain noun / `_type`
  with a `CHECK`, never `_id`.
- `inventory_txn` and `qc_test` are **append-only** — corrections are new rows.
- Balances and costs are **derived** (summed from the ledger), never stored as mutable
  columns.
