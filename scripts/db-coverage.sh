#!/usr/bin/env bash
# Database function coverage: which server functions and triggers in `public`
# the pgTAP suite runs at least once, compared with coverage-baseline.json.
#
# Postgres counts calls per function (track_functions, turned on by
# supabase/tests/helpers/setup.psql), including calls inside the rolled-back
# transaction each test file runs in. This script snapshots the counts, runs
# `supabase test db`, and works out which functions were called in between.
# It can't see which lines inside a function ran; the per-rule tests cover
# that.
#
# Usage:  ./scripts/db-coverage.sh            report, and fail if coverage dropped
#         ./scripts/db-coverage.sh --update   save the result as the baseline
#
# Needs the local stack (`supabase start`) with an empty database, as the
# tests do: run `npx supabase@2.118.0 db reset` first if it has data in it.
# Only the local database is accepted, since the snapshot is per database.
set -euo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
case "$DB_URL" in
  *@127.0.0.1:*|*@localhost:*) ;;
  *) echo "db-coverage.sh only runs against the local database (got a non-local DB_URL)." >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE="$ROOT/coverage-baseline.json"
REPORT_DIR="$ROOT/coverage"
REPORT="$REPORT_DIR/db-coverage.json"
UPDATE=false
[[ "${1:-}" == "--update" ]] && UPDATE=true
mkdir -p "$REPORT_DIR"

psql_run() { psql "$DB_URL" -v ON_ERROR_STOP=1 -qAt "$@"; }

# Calls so far per function, as {"name(args)": calls}.
snapshot() {
  psql_run -c "select coalesce(jsonb_object_agg(funcid::regprocedure::text, calls), '{}')
               from pg_stat_user_functions where schemaname = 'public'"
}

# 1. Count calls before the run, run the suite, count again.
BEFORE=$(snapshot)
if ! (cd "$ROOT" && npx -y supabase@2.118.0 test db); then
  echo >&2
  echo "The database tests failed, so coverage wasn't measured. Fix the failing tests;" >&2
  echo "if the database has data in it, run \`npx supabase@2.118.0 db reset\` first." >&2
  exit 1
fi
# Each test file's connection reports its counts when it closes; give the
# stats collector a moment.
sleep 1
AFTER=$(snapshot)

# 2. Every function in public (extension members excluded), tested or not.
psql_run -v before="$BEFORE" -v after="$AFTER" > "$REPORT" <<'SQL'
with functions as (
  select p.oid::regprocedure::text as name
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join pg_language l on l.oid = p.prolang
  where n.nspname = 'public'
    and l.lanname in ('plpgsql', 'sql')
    and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
),
called as (
  select name,
         coalesce((:'after'::jsonb ->> name)::bigint, 0) - coalesce((:'before'::jsonb ->> name)::bigint, 0) as calls
  from functions
)
select jsonb_pretty(jsonb_build_object(
  'functionsTested', count(*) filter (where calls > 0),
  'functionsTotal', count(*),
  'percent', round(100.0 * count(*) filter (where calls > 0) / greatest(count(*), 1), 2),
  'tested', coalesce(jsonb_agg(name order by name) filter (where calls > 0), '[]'),
  'untested', coalesce(jsonb_agg(name order by name) filter (where calls = 0), '[]')
))
from called;
SQL

# Run a query that reads the report (and the baseline) as psql variables,
# which psql only fills in for SQL read from stdin, not from -c.
report_query() {
  local baseline='{}'
  [[ -f "$BASELINE" ]] && baseline="$(cat "$BASELINE")"
  psql_run -v report="$(cat "$REPORT")" -v baseline="$baseline" <<< "$1"
}
summary() {
  report_query "select format('%s of %s functions tested (%s%%)',
    :'report'::jsonb->>'functionsTested', :'report'::jsonb->>'functionsTotal', :'report'::jsonb->>'percent')"
}
untested() {
  report_query "select '  - ' || jsonb_array_elements_text(:'report'::jsonb->'untested')"
}

echo
echo "Database function coverage: $(summary)"
if [[ -n "$(untested)" ]]; then
  echo "Never called by the tests:"
  untested
fi

# 3. Save as the baseline, or compare with it.
if $UPDATE; then
  report_query "select jsonb_pretty(jsonb_build_object(
    'updated', '$(date +%F)', 'database', :'report'::jsonb))" > "$BASELINE.new"
  mv "$BASELINE.new" "$BASELINE"
  echo
  echo "Baseline saved to coverage-baseline.json."
  exit 0
fi

if [[ ! -f "$BASELINE" ]]; then
  echo "No coverage-baseline.json yet. Run ./scripts/db-coverage.sh --update to create it." >&2
  exit 1
fi

# Fails when a function the baseline counts as tested isn't any more (it lost
# its tests, or was renamed without them), or the % dropped. A new function
# without tests lowers the %, so adding one means updating the baseline
# deliberately in the same commit.
report_query "$(cat <<'SQL'
with r as (select :'report'::jsonb as now, :'baseline'::jsonb -> 'database' as was),
lost as (
  select name from r, jsonb_array_elements_text(now->'untested') as name
  where was->'tested' ? name
),
added as (
  select name from r, jsonb_array_elements_text(now->'untested') as name
  where not (was->'tested' ? name) and not (was->'untested' ? name)
)
select 'lost ' || name from lost
union all
select 'new-untested ' || name from added
union all
select 'percent ' || (now->>'percent') || ' ' || (was->>'percent') from r;
SQL
)" > "$REPORT_DIR/db-coverage-check.txt"

STATUS=0
WAS_PERCENT=""; NOW_PERCENT=""
while read -r kind name extra; do
  case "$kind" in
    lost) echo "  ✗ no longer tested: $name"; STATUS=1 ;;
    new-untested) echo "  ✗ new function with no tests: $name" ;;
    percent) NOW_PERCENT="$name"; WAS_PERCENT="$extra" ;;
  esac
done < "$REPORT_DIR/db-coverage-check.txt"

echo
if awk -v now="$NOW_PERCENT" -v was="$WAS_PERCENT" 'BEGIN { exit !(now < was) }'; then
  echo "Coverage dropped below the baseline: ${WAS_PERCENT}% → ${NOW_PERCENT}%." >&2
  STATUS=1
fi
if [[ $STATUS -ne 0 ]]; then
  echo "Add tests, or if this is intended, run ./scripts/db-coverage.sh --update and commit the baseline." >&2
  exit 1
fi
echo "Coverage is at or above the baseline (${NOW_PERCENT}%, baseline ${WAS_PERCENT}%)."
if awk -v now="$NOW_PERCENT" -v was="$WAS_PERCENT" 'BEGIN { exit !(now > was) }'; then
  echo "Run ./scripts/db-coverage.sh --update to raise the baseline in this commit."
fi
