# AceStock — backend and iOS

AceStock is a point of sale, inventory and stringing system for racquet-sport shops.
This repository holds the parts shared by every client, plus the iOS app. (`CastLedger`
is the project's original code name.)

| Path | What it is |
|------|------------|
| [`supabase/`](supabase/README.md) | Database schema (migrations), server functions, database tests, seed data |
| [`ENVIRONMENTS.md`](ENVIRONMENTS.md) | Test vs. production databases and how to apply migrations to each |
| `scripts/` | Repo tooling (e.g. building `supabase/apply_all.sql`) |
| [`ios/`](ios/README.md) | iOS companion app. Still contains the earlier precast-era screens, which will be replaced in roadmap subphase 5A |

The web app lives in its own repository, `cast-ledger-webapp`.
