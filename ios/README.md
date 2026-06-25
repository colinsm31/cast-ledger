# CastLedger — iOS app

SwiftUI (iOS / iPadOS 16+) client for the Waskey IPM system. MVVM, feature-module
structure. The Xcode project is generated from `project.yml` with **XcodeGen** —
the `.xcodeproj` is not committed.

## One-time setup

### 1. Install XcodeGen

```bash
brew install xcodegen          # or: mint install yonaskolb/xcodegen
xcodegen --version
```

### 2. Add your Supabase config (not committed)

```bash
cp Secrets.xcconfig.sample Secrets.xcconfig
```

Edit `Secrets.xcconfig` and fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY` from
the Supabase dashboard (Project Settings → API). `Secrets.xcconfig` is gitignored.

> The URL keeps its `https://` via the `SLASHES` trick in the file — xcconfig
> otherwise treats `//` as a comment. Leave that line as written.

### 3. Generate and open the project

```bash
xcodegen generate
open CastLedger.xcodeproj      # or: xed .
```

Build & run on an iPhone or iPad simulator (iOS 16+). On first launch the app
shows a "Backend connected" shell if config is valid, or a clear "Setup needed"
screen if `Secrets.xcconfig` is missing/placeholder.

## Day-to-day

Run `xcodegen generate` again whenever source files are **added or renamed** (the
folder tree is the source of truth). Editing existing files needs no regeneration.

## Layout

```
ios/
  project.yml                  XcodeGen spec (target, deps, settings)
  Secrets.xcconfig.sample      template for Supabase config (copy → Secrets.xcconfig)
  Sources/
    App/                       entry point, environment, root view, Info.plist
    Core/                      AppConfig, Supabase client provider, EmptyStateView
    Models/
      Core/                    JSONValue (JSONB bridge), domain enums
      Entities.swift           Codable mirrors of the Postgres tables
      Inserts.swift            insert payloads for append-only / create paths
    Features/
      Auth/                    AuthService, sign-in screen + view model
      Home/                    signed-in shell + categories smoke test
      TemplateDefiner/         spec-template definer (list + editor, RPC repository)
    Resources/                 Assets.xcassets
  Tests/                       unit tests (JSONValue round-trip, enum decoding)
```

## Backend migrations required

Beyond Phase 0 (`0001`–`0003`), the template definer needs:

- `supabase/migrations/0004_create_product_design_fn.sql` — the atomic
  `create_product_design` RPC (inserts the design + its spec_attribute rows +
  the spec_template JSONB mirror in one transaction). Apply it in the Supabase
  SQL Editor before using the "Product families → New family" screen.
- `supabase/migrations/0005_lookup_values.sql` — the `lookup_values` table +
  `add_lookup_value` (insert-if-missing) RPC + seed. Powers the pick-or-add
  fields (units, field names, enum values) in the template editor so engineers
  pick from a shared list or add a new value inline (saved immediately).
- `supabase/migrations/0006_create_piece_fn.sql` — the `create_piece` RPC. The
  server pins the as-poured design revision from the design itself and starts the
  piece at status `in_production`. Powers the "New piece" template-driven editor.

## Dependencies

[`supabase-swift`](https://github.com/supabase/supabase-swift) (pinned `from: 2.46.0`),
products **Auth + PostgREST + Realtime**. Storage/Functions are intentionally left
out for Phase 1.

## Conventions

MVVM; group by feature/module; MARK sections; descriptive names; `guard let` over
force-unwrap; closed sets as enums; secrets out of source. Auth sessions persist in
the iOS Keychain (handled by the Supabase SDK). Models use a global snake_case ↔
camelCase key strategy, so no per-field `CodingKeys`.
