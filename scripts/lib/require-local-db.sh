# Sourced by scripts that create, change or delete rows: they only ever run
# against the local Supabase stack, never a hosted project.
#
#   source "$(dirname "$0")/lib/require-local-db.sh"
#   require_local_db "$DB_URL"
require_local_db() {
  case "$1" in
    *@127.0.0.1:*|*@localhost:*) ;;
    *)
      echo "$(basename "$0") only runs against the local database (got a non-local DB_URL)." >&2
      exit 1
      ;;
  esac
}
