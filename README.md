# Waskey IPM — Inventory & Production Management

Internal, single-tenant inventory + production-management system for **Waskey
Bridges, Inc.**, a Baton Rouge custom-precast concrete manufacturer. This repo is
the build; the planning docs live separately in `Documents/Inventory_Manager_Plans`.

See the plans for the full rationale. One-line version: off-the-shelf ERPs force
every product into a rigid item-master, but Waskey's work is mostly one-off
engineer-to-order pieces. This system uses a **template / instance** model — a
`product_design` is a reusable template, a `piece` is a serialized instance cloned
from it — so custom pieces never become throwaway SKUs, while specs stay validated
and QC stays fully traceable.

## Stack (locked)

- **Client:** SwiftUI (iOS / iPadOS) — *added in a later pass.*
- **Backend:** Supabase — Postgres (JSONB for flexible specs, relational core, RLS),
  Auth, Realtime.
- **Connectivity (v1):** online-required. The append-only ledger + client-generated
  UUIDs keep an offline queue possible later without a rewrite.

## Current state — Phase 0 (backend)

This pass is **Supabase backend only**: the core Postgres schema, RLS/auth policies,
and Waskey seed fixtures. The SwiftUI app shell comes in a following pass.

```
supabase/
  migrations/
    0001_core_schema.sql      -- core tables, constraints, indexes
    0002_rls_policies.sql     -- row-level security + append-only enforcement
  seed/
    seed.sql                  -- Waskey product families, material categories, yard locations
  README.md                   -- how to apply migrations locally / to a Supabase project
```

## Conventions adopted

This project follows the code standards in the project instructions and the relevant
practices from the SkyCoach infrastructure rule corpus (treated as read-only
reference; its git/Jira rules do **not** apply here):

- **Postgres naming** — snake_case identifiers, plural tables, PK `id`; `<singular>_id`
  only for real foreign keys. Closed-set columns use a domain noun or `_type`, never
  `_id` (e.g. `status`, `txn_type`).
- **Append-only ledgers** — `inventory_txn` and `qc_test` are insert-only; corrections
  are new rows, never edits. Enforced in the DB via RLS (no UPDATE/DELETE grants).
- **No secrets in the repo** — real credentials are injected from the environment;
  only `.env.sample` is committed. See `.gitignore`.
- **Build only what the requirement needs** — Phase 0 scope only; no speculative tables
  for later phases (delivery, purchase orders, etc.).

## Getting started (local)

1. Copy `.env.sample` → `.env` and fill in real values (gitignored).
2. Install the [Supabase CLI](https://supabase.com/docs/guides/cli), then
   `supabase start` and `supabase db reset` to apply migrations + seed locally,
   **or** apply `supabase/migrations/*.sql` then `supabase/seed/seed.sql` against any
   Postgres with `psql`. See `supabase/README.md`.
