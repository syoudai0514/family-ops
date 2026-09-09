#!/usr/bin/env bash
# CF-11 right-sized recovery drill.
#
# Fetch the latest durable household/domain snapshot from the existing
# separate app-save-hub Supabase project and restore it into an EMPTY,
# disposable Supabase-compatible database whose schema has already been
# created from the Family Ops repository migrations.
#
# Provider credentials/sessions/queues/cron state are intentionally not part
# of the snapshot. For FK validation in the disposable drill we create only
# placeholder auth.users rows carrying the original UUID/email references;
# this does not claim that Google/LINE/Auth provider sessions were restored.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLES_FILE="${RECOVERY_TABLES_FILE:-$ROOT/scripts/family_ops_recovery_tables.txt}"
TARGET_PROJECT_REF="${TARGET_PROJECT_REF:-wdwbmvpipbdpomqulsrj}"
SOURCE_PROJECT_REF="${SOURCE_PROJECT_REF:-dnlqxjpjpkxnfgculzip}"
SCRATCH_DB_URL=""
SNAPSHOT_FILE=""

usage() {
  cat <<'USAGE'
Usage: scripts/restore_drill.sh --scratch-db-url <url> [--snapshot-file <json>]

Options:
  --scratch-db-url <url>  REQUIRED. Empty disposable Supabase-compatible DB
                          with current Family Ops migrations already applied.
  --snapshot-file <json>  Optional local snapshot payload. If omitted, the
                          latest Family Ops payload is read from app-save-hub
                          using SUPABASE_ACCESS_TOKEN.
  -h, --help              Show help.

Safety:
  By default the target URL must be localhost/127.0.0.1. A managed target is
  refused unless ALLOW_MANAGED_RECOVERY_TARGET=1 is explicitly set.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --scratch-db-url)
      [ $# -ge 2 ] || { echo "ERROR: --scratch-db-url requires a value" >&2; exit 2; }
      SCRATCH_DB_URL="$2"; shift 2 ;;
    --snapshot-file)
      [ $# -ge 2 ] || { echo "ERROR: --snapshot-file requires a value" >&2; exit 2; }
      SNAPSHOT_FILE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$SCRATCH_DB_URL" ]; then
  echo "ERROR: --scratch-db-url is required" >&2
  exit 2
fi
if [ "${ALLOW_MANAGED_RECOVERY_TARGET:-0}" != "1" ]; then
  case "$SCRATCH_DB_URL" in
    *"@127.0.0.1:"*|*"@localhost:"*|*"host=127.0.0.1"*|*"host=localhost"*) ;;
    *)
      echo "ERROR: refusing a non-local recovery target without ALLOW_MANAGED_RECOVERY_TARGET=1" >&2
      exit 3
      ;;
  esac
fi
if [ ! -s "$TABLES_FILE" ]; then
  echo "ERROR: recovery table allowlist is missing or empty" >&2
  exit 2
fi
for cmd in jq psql base64 cmp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command '$cmd' is missing" >&2; exit 2; }
done

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

mapfile -t TABLES < <(sed -E 's/[[:space:]]+#.*$//' "$TABLES_FILE" | sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d')
for table in "${TABLES[@]}"; do
  [[ "$table" =~ ^public\.[a-z][a-z0-9_]*$ ]] || { echo "ERROR: invalid recovery table identifier: $table" >&2; exit 2; }
done

SNAPSHOT="$WORKDIR/snapshot.json"
if [ -n "$SNAPSHOT_FILE" ]; then
  [ -s "$SNAPSHOT_FILE" ] || { echo "ERROR: --snapshot-file is missing or empty" >&2; exit 2; }
  cp "$SNAPSHOT_FILE" "$SNAPSHOT"
else
  command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required when fetching from app-save-hub" >&2; exit 2; }
  [ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || { echo "ERROR: SUPABASE_ACCESS_TOKEN is required when --snapshot-file is omitted" >&2; exit 2; }
  RESPONSE="$WORKDIR/latest.json"
  SQL="select payload from public.app_saves where app_id='family-ops' and slot_id='household' order by updated_at desc limit 1;"
  jq -n --arg query "$SQL" '{query: $query}' \
    | curl --fail-with-body --silent --show-error \
        -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d @- \
        "https://api.supabase.com/v1/projects/${TARGET_PROJECT_REF}/database/query" \
        > "$RESPONSE"
  jq -e 'length == 1 and (.[0].payload | type) == "object"' "$RESPONSE" >/dev/null || {
    echo "ERROR: no valid Family Ops snapshot exists in app-save-hub" >&2
    exit 1
  }
  jq '.[0].payload' "$RESPONSE" > "$SNAPSHOT"
fi

jq -e --arg source "$SOURCE_PROJECT_REF" '
  .schema_version == 1 and
  .source_project_ref == $source and
  .restore_scope == "durable-household-domain" and
  (.auth_user_refs | type) == "array" and
  (.auth_user_refs | length) >= 1 and
  (.tables | type) == "object" and
  (.row_counts | type) == "object"
' "$SNAPSHOT" >/dev/null || {
  echo "ERROR: recovery snapshot metadata is invalid" >&2
  exit 1
}

EXPECTED_KEYS="$WORKDIR/expected-keys.txt"
ACTUAL_KEYS="$WORKDIR/actual-keys.txt"
printf '%s\n' "${TABLES[@]}" | sort > "$EXPECTED_KEYS"
jq -r '.tables | keys[]' "$SNAPSHOT" | sort > "$ACTUAL_KEYS"
if ! cmp -s "$EXPECTED_KEYS" "$ACTUAL_KEYS"; then
  echo "ERROR: snapshot table set does not exactly match the reviewed recovery allowlist" >&2
  diff -u "$EXPECTED_KEYS" "$ACTUAL_KEYS" >&2 || true
  exit 1
fi
for table in "${TABLES[@]}"; do
  jq -e --arg table "$table" '.tables[$table] | type == "array"' "$SNAPSHOT" >/dev/null || {
    echo "ERROR: snapshot table payload is not an array: $table" >&2
    exit 1
  }
done

# The disposable target must already have schema from repository migrations,
# and no household data. This drill never resets or deletes production.
SCRATCH_MIGRATION="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select version from supabase_migrations.schema_migrations order by version desc limit 1;")"
SNAPSHOT_MIGRATION="$(jq -r '.source_migration_version' "$SNAPSHOT")"
if [ -z "$SCRATCH_MIGRATION" ] || [ "$SCRATCH_MIGRATION" != "$SNAPSHOT_MIGRATION" ]; then
  echo "ERROR: scratch schema migration version ($SCRATCH_MIGRATION) does not match snapshot ($SNAPSHOT_MIGRATION)" >&2
  exit 1
fi

for table in "${TABLES[@]}"; do
  EXISTS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select to_regclass('${table}') is not null;")"
  [ "$EXISTS" = "t" ] || { echo "ERROR: scratch schema is missing $table" >&2; exit 1; }
done

EXISTING_HOUSEHOLDS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c 'select count(*) from public.households;')"
if [ "$EXISTING_HOUSEHOLDS" != "0" ]; then
  echo "ERROR: scratch target already contains household data; refusing restore" >&2
  exit 1
fi

# Insert placeholder Auth rows with triggers disabled so the drill can enforce
# the real public-table FKs without copying passwords/OAuth identities/sessions.
AUTH_JSON="$WORKDIR/auth-refs.json"
jq '.auth_user_refs' "$SNAPSHOT" > "$AUTH_JSON"
AUTH_B64="$WORKDIR/auth.b64"
base64 -w0 "$AUTH_JSON" > "$AUTH_B64"
AUTH_SQL="$WORKDIR/auth.sql"
cat > "$AUTH_SQL" <<'SQL'
set session_replication_role = replica;
insert into auth.users (id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select x.id::uuid, 'authenticated', 'authenticated', x.email, now(), now(), false, false
from jsonb_to_recordset(convert_from(decode('
SQL
cat "$AUTH_B64" >> "$AUTH_SQL"
cat >> "$AUTH_SQL" <<'SQL'
', 'base64'), 'UTF8')::jsonb) as x(id text, email text)
on conflict (id) do nothing;
set session_replication_role = origin;
SQL
psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -q -f "$AUTH_SQL"

# Restore in the reviewed dependency order with normal FK/check constraints
# active. Any missing dependency or type/schema drift fails the drill.
for table in "${TABLES[@]}"; do
  table_name="${table#public.}"
  TABLE_JSON="$WORKDIR/${table_name}.json"
  jq --arg table "$table" '.tables[$table]' "$SNAPSHOT" > "$TABLE_JSON"
  expected="$(jq 'length' "$TABLE_JSON")"
  if [ "$expected" = "0" ]; then
    continue
  fi
  TABLE_B64="$WORKDIR/${table_name}.b64"
  base64 -w0 "$TABLE_JSON" > "$TABLE_B64"
  SQL_FILE="$WORKDIR/restore-${table_name}.sql"
  printf "insert into %s select * from jsonb_populate_recordset(null::%s, convert_from(decode('" "$table" "$table" > "$SQL_FILE"
  cat "$TABLE_B64" >> "$SQL_FILE"
  cat >> "$SQL_FILE" <<'SQL'
', 'base64'), 'UTF8')::jsonb);
SQL
  psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -q -f "$SQL_FILE"
done

# Exact row-count equality is the minimum recovery proof for every in-scope
# table. FK/check enforcement was active during inserts, so successful restore
# also proves the selected domain graph is internally loadable.
for table in "${TABLES[@]}"; do
  expected="$(jq -r --arg table "$table" '.row_counts[$table]' "$SNAPSHOT")"
  actual="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select count(*) from ${table};")"
  if [ "$actual" != "$expected" ]; then
    echo "ERROR: restored row count mismatch for $table (expected=$expected actual=$actual)" >&2
    exit 1
  fi
done

AUTH_ORPHANS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select (select count(*) from public.household_members hm left join auth.users u on u.id=hm.user_id where u.id is null) + (select count(*) from public.profiles p left join auth.users u on u.id=p.user_id where u.id is null);")"
TASK_ORPHANS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select count(*) from public.task_instances ti left join public.households h on h.id=ti.household_id left join public.task_definitions td on td.id=ti.task_definition_id and td.household_id=ti.household_id where h.id is null or (ti.task_definition_id is not null and td.id is null);")"
SUBTASK_ORPHANS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select count(*) from public.task_subtask_instances si left join public.task_instances ti on ti.id=si.task_instance_id and ti.household_id=si.household_id where ti.id is null;")"

if [ "$AUTH_ORPHANS" != "0" ] || [ "$TASK_ORPHANS" != "0" ] || [ "$SUBTASK_ORPHANS" != "0" ]; then
  echo "ERROR: restored household graph has identity/task linkage orphans" >&2
  exit 1
fi

HOUSEHOLDS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c 'select count(*) from public.households;')"
MEMBERS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c 'select count(*) from public.household_members;')"
TASKS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c 'select count(*) from public.task_instances;')"
SUBTASKS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c 'select count(*) from public.task_subtask_instances;')"
if [ "$HOUSEHOLDS" -lt 1 ] || [ "$MEMBERS" -lt 1 ] || [ "$TASKS" -lt 1 ]; then
  echo "ERROR: restored foundational household data is unexpectedly empty" >&2
  exit 1
fi

echo "Recovered household graph: households=${HOUSEHOLDS}, members=${MEMBERS}, tasks=${TASKS}, subtasks=${SUBTASKS}"
echo "RESULT: PASS — latest separate-project snapshot restored into disposable Supabase with typed rows, FK checks and exact row counts"
