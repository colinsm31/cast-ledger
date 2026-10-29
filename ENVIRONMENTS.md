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

**Brand-new databases only.** Some early migrations drop tables and empty the sales
history, so the file starts with a check that refuses any database that already has
a `sales` table, and runs as one transaction: if it stops, nothing is applied. To
update an existing database, apply new migrations one at a time.

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
runs *new* ones going forward.

First confirm which migrations production actually has. Every migration through
`0034` was written before the CLI was adopted, so all of them were applied by hand
in the SQL editor; check that the newest ones (`0030`–`0034`) really were. For example,
`select to_regclass('public.product_units');` should return `product_units`
(created by `0032`). Then mark exactly those as applied:

```
supabase link --project-ref YOUR-PROD-ref
supabase migration repair --status applied \
  0001 0002 0003 0004 0005 0006 0007 0008 0009 0010 \
  0011 0012 0013 0014 0015 0016 0017 0018 0019 0020 \
  0021 0022 0023 0024 0025 0026 0027 0028 0029 0030 \
  0031 0032 0033 0034
supabase migration list     # local and remote columns should now match through 0034
```

After that, the normal deploy flow is: add a new migration file → apply it to the
**test** project and run the app there → `supabase db push` to production. (The
repair step is only needed once, and only on the existing prod DB.) Migrations from
`0035` on are never applied by hand, so they never need repairing.

---

## Accounts: sign-up off, first admin, adding staff

Only approved staff can use the shop's data (migration `0041`). New accounts start
as `pending`, which has no access, and staff accounts are created by admins through
the `create-staff` Edge Function. Set up every hosted project like this:

1. **Turn off public sign-up:** Authentication → Sign In / Providers → turn **off**
   "Allow new users to sign up". (Keep the Email provider itself on, so staff can
   sign in.) Locally this is `enable_signup = false` under `[auth]` in
   `supabase/config.toml`.
2. **Minimum password length 8:** Authentication → Policies (or Sign In / Providers →
   Email) → "Minimum password length" = 8, so the server refuses short passwords too,
   not just the app's screens. Locally this is `minimum_password_length = 8` under
   `[auth]`.
3. **Deploy the Edge Function** (once, and again whenever it changes):

   ```
   supabase functions deploy create-staff --project-ref YOUR-PROJECT-ref
   ```

4. **First admin:** create your own account in the dashboard (Authentication →
   Users → Add user, with "Auto Confirm User" on), then promote it in the SQL editor:

   ```sql
   update profiles set role = 'admin' where email = 'you@yourshop.com';
   ```

5. **Everyone else:** an admin adds them on the app's Users screen ("Add staff
   account") with a temporary password. The app asks them to change it on the
   My account page. An account created any other way (e.g. in the dashboard) shows as
   "no access" there until an admin approves it.

---

## Local development and database tests

Run the whole stack on your laptop with Docker — no hosted project needed. The CLI
works through npx if it isn't installed:

```
npx supabase@2.118.0 start      # boots Postgres + Auth + API, applies migrations + sample seed
npx supabase@2.118.0 test db    # runs the pgTAP tests in supabase/tests
npx supabase@2.118.0 db reset   # rebuild the local database after changing a migration
```

**Database function coverage:** `./scripts/db-coverage.sh` runs the pgTAP tests and
lists every server function or trigger they never call. It fails if a function that
was tested no longer is, or if the share of tested functions is below
`coverage-baseline.json`. When a commit adds tests, or adds a function without tests
on purpose, run `./scripts/db-coverage.sh --update` and commit the new baseline with
it. It needs an empty local database, as the tests do (`db reset` first), and only
counts whether each function ran, not which lines inside it. Not part of CI yet.

`supabase start` prints a local `API URL` and `anon key`. To point the web app at the
local stack without touching your normal `web/.env.local`, put them in
`web/.env.localdb.local` and run `npm run dev -- --mode localdb`.
