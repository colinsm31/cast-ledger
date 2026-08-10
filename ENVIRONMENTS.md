# Environments (test vs. production)

Each environment is its **own Supabase project** = its own Postgres database,
auth users, and data. Nothing is shared between test and production. The web app
picks which database it talks to purely from two env vars, so switching
environments never requires code changes.

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`

Recommended layout:

| Environment | Supabase project | Web config |
|-------------|------------------|------------|
| Production  | `acestock` (existing) | env vars set in your host (Vercel/Netlify/etc.) |
| Test / staging | `acestock-test` (new project) | `web/.env.local` |
| Local (optional) | `supabase start` (Docker) | `web/.env.local` |

---

## Switching the web app between environments

The app reads `web/.env.local` in development (gitignored). Point it at whichever
project you're working against:

```
# web/.env.local  → test project
VITE_SUPABASE_URL=https://YOUR-TEST-ref.supabase.co
VITE_SUPABASE_ANON_KEY=your-test-anon-key
```

For the production build, set the same two variables in your hosting provider's
environment settings (not in a committed file). Same code, different target.

---

## Standing up a NEW database (e.g. the test project)

Create the project in the Supabase dashboard, then apply the schema one of these
ways. All three produce the same result; pick what you like.

### A. Supabase CLI (recommended, repeatable)

```
# once: install the CLI and log in
brew install supabase/tap/supabase
supabase login

# from the CastLedger repo root, link to the TEST project and push
supabase link --project-ref YOUR-TEST-ref
supabase db push            # applies every migration in supabase/migrations
```

Sample data (optional): run `supabase/seed/tennis_seed.sql` against the project
(SQL editor, or `psql < supabase/seed/tennis_seed.sql`).

### B. One-file paste (no CLI)

Open `supabase/apply_all.sql` (all migrations concatenated, in order), paste it
into the test project's **SQL Editor**, and run it. Then paste
`supabase/seed/tennis_seed.sql` for sample data.

Regenerate that file after adding/editing migrations:

```
./scripts/build-apply-all.sh
```

### C. psql

```
for f in supabase/migrations/*.sql; do psql "$TEST_DB_URL" -f "$f"; done
psql "$TEST_DB_URL" -f supabase/seed/tennis_seed.sql   # optional sample data
```

---

## Adopting the CLI on the EXISTING production project

Production was migrated by hand (SQL editor), so its migration-tracking table is
empty. If you run `supabase db push` against it as-is, the CLI thinks **nothing**
is applied and will try to re-run everything — including `0008`, which drops and
rebuilds tables and **would wipe data**. Don't do that.

Instead, mark the already-applied migrations as applied once, so push only ever
runs *new* ones going forward:

```
supabase link --project-ref YOUR-PROD-ref
supabase migration repair --status applied \
  0001 0002 0003 0004 0005 0006 0007 0008 0009 0010 \
  0011 0012 0013 0014 0015 0016 0017 0018 0019 0020 \
  0021 0022 0023 0024 0025 0026 0027 0028 0029
```

After that, the normal deploy flow is: add a new migration file → `supabase db
push`. (This repair step is only needed once, and only on the existing prod DB.)

---

## First admin

Roles default to `staff`. After the schema is applied and you've signed in once
(so a profile row exists), promote yourself in the SQL editor:

```sql
update profiles set role = 'admin' where email = 'you@yourshop.com';
```

Also, so "Add staff" works without hitting the email rate limit: Authentication →
Providers → Email → turn **off** "Confirm email" (already the default in
`supabase/config.toml` for local).

---

## Local development (optional)

Run the whole stack on your laptop — no hosted project needed:

```
supabase start        # boots Postgres + Auth + Studio in Docker
supabase db reset     # applies migrations + supabase/seed.sql
```

`supabase start` prints a local `API URL` and `anon key`; put those in
`web/.env.local` to develop entirely offline.
