#!/usr/bin/env bash
# CF-11 right-sized recovery drill.
#
# Restores the latest durable household/domain snapshot into an EMPTY disposable
# Supabase schema. Production Auth secrets/sessions are never copied. Instead,
# prepare_recovery_auth_smoke.sh first creates new Auth users and this script
# rebinds old snapshot user UUIDs to those new UUIDs in every schema-declared
# user foreign-key column before typed insertion with normal constraints active.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLES_FILE="${RECOVERY_TABLES_FILE:-$ROOT/scripts/family_ops_recovery_tables.txt}"
TARGET_PROJECT_REF="${TARGET_PROJECT_REF:-wdwbmvpipbdpomqulsrj}"
SOURCE_PROJECT_REF="${SOURCE_PROJECT_REF:-dnlqxjpjpkxnfgculzip}"
APP_ID="family-ops-recovery-v1"
SLOT_ID="household-durable-v1"
SCRATCH_DB_URL=""
SNAPSHOT_FILE=""
IDENTITY_MAP_FILE=""

usage() {
  cat <<'USAGE'
Usage: scripts/restore_drill.sh --scratch-db-url <url> --identity-map <json> [--snapshot-file <json>]

Options:
  --scratch-db-url <url>  REQUIRED. Empty disposable Supabase-compatible DB
                          with current Family Ops migrations already applied.
  --identity-map <json>   REQUIRED. Mode-0600 JSON produced by
                          prepare_recovery_auth_smoke.sh (old_id/new_id/token).
  --snapshot-file <json>  Optional payload. Otherwise read latest reserved
                          Family Ops snapshot from app-save-hub.
  -h, --help              Show help.

Safety:
  Target must be localhost/127.0.0.1 unless ALLOW_MANAGED_RECOVERY_TARGET=1.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --scratch-db-url)
      [ $# -ge 2 ] || { echo "ERROR: --scratch-db-url requires a value" >&2; exit 2; }
      SCRATCH_DB_URL="$2"; shift 2 ;;
    --identity-map)
      [ $# -ge 2 ] || { echo "ERROR: --identity-map requires a value" >&2; exit 2; }
      IDENTITY_MAP_FILE="$2"; shift 2 ;;
    --snapshot-file)
      [ $# -ge 2 ] || { echo "ERROR: --snapshot-file requires a value" >&2; exit 2; }
      SNAPSHOT_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$SCRATCH_DB_URL" ] || { echo "ERROR: --scratch-db-url is required" >&2; exit 2; }
[ -s "$IDENTITY_MAP_FILE" ] || { echo "ERROR: --identity-map is required and must be non-empty" >&2; exit 2; }
if [ "${ALLOW_MANAGED_RECOVERY_TARGET:-0}" != "1" ]; then
  case "$SCRATCH_DB_URL" in
    *"@127.0.0.1:"*|*"@localhost:"*|*"host=127.0.0.1"*|*"host=localhost"*) ;;
    *) echo "ERROR: refusing non-local recovery target without ALLOW_MANAGED_RECOVERY_TARGET=1" >&2; exit 3 ;;
  esac
fi
[ -s "$TABLES_FILE" ] || { echo "ERROR: recovery table allowlist is missing or empty" >&2; exit 2; }
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
  SQL="select payload from public.app_saves where user_id=(select id from auth.users order by created_at nulls last, id limit 1) and app_id='${APP_ID}' and slot_id='${SLOT_ID}' limit 1;"
  jq -n --arg query "$SQL" '{query: $query}' \
    | curl --fail-with-body --silent --show-error \
        -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
        -H 'Content-Type: application/json' -d @- \
        "https://api.supabase.com/v1/projects/${TARGET_PROJECT_REF}/database/query" > "$RESPONSE"
  jq -e 'length == 1 and (.[0].payload | type) == "object"' "$RESPONSE" >/dev/null || {
    echo "ERROR: no valid Family Ops snapshot exists in app-save-hub" >&2; exit 1;
  }
  jq '.[0].payload' "$RESPONSE" > "$SNAPSHOT"
fi

jq -e --arg source "$SOURCE_PROJECT_REF" --arg app "$APP_ID" --arg slot "$SLOT_ID" '
  .schema_version == 1 and .source_project_ref == $source and
  .restore_scope == "durable-household-domain" and
  .recovery_namespace.app_id == $app and .recovery_namespace.slot_id == $slot and
  (.auth_user_refs | type) == "array" and (.auth_user_refs | length) >= 1 and
  (.tables | type) == "object" and (.row_counts | type) == "object"
' "$SNAPSHOT" >/dev/null || { echo "ERROR: recovery snapshot metadata is invalid" >&2; exit 1; }

EXPECTED_KEYS="$WORKDIR/expected-keys.txt"
ACTUAL_KEYS="$WORKDIR/actual-keys.txt"
printf '%s\n' "${TABLES[@]}" | sort > "$EXPECTED_KEYS"
jq -r '.tables | keys[]' "$SNAPSHOT" | sort > "$ACTUAL_KEYS"
cmp -s "$EXPECTED_KEYS" "$ACTUAL_KEYS" || {
  echo "ERROR: snapshot table set does not exactly match reviewed allowlist" >&2
  diff -u "$EXPECTED_KEYS" "$ACTUAL_KEYS" >&2 || true
  exit 1
}
for table in "${TABLES[@]}"; do
  jq -e --arg table "$table" '.tables[$table] | type == "array"' "$SNAPSHOT" >/dev/null || {
    echo "ERROR: snapshot table payload is not an array: $table" >&2; exit 1;
  }
done

# Supabase migration history identifiers are deployment metadata, not a safe
# schema-compatibility oracle: the same reviewed migration can receive a
# different remote timestamp when applied through the Management API/tooling.
# Require both histories to exist, but prove compatibility with the actual
# typed restore + constraints + source-field content equality below.
SCRATCH_MIGRATION="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select version from supabase_migrations.schema_migrations order by version desc limit 1;")"
SNAPSHOT_MIGRATION="$(jq -r '.source_migration_version // empty' "$SNAPSHOT")"
[ -n "$SCRATCH_MIGRATION" ] && [ -n "$SNAPSHOT_MIGRATION" ] || {
  echo "ERROR: source or scratch migration history is missing" >&2; exit 1;
}
if [ "$SCRATCH_MIGRATION" != "$SNAPSHOT_MIGRATION" ]; then
  echo "INFO: migration identifiers differ (snapshot=${SNAPSHOT_MIGRATION}, scratch=${SCRATCH_MIGRATION}); proving data compatibility directly"
fi
for table in "${TABLES[@]}"; do
  [ "$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select to_regclass('${table}') is not null;")" = "t" ] || {
    echo "ERROR: scratch schema is missing $table" >&2; exit 1;
  }
done
[ "$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c 'select count(*) from public.households;')" = "0" ] || {
  echo "ERROR: scratch target already contains household data; refusing restore" >&2; exit 1;
}

# Validate that the prepared Auth map covers every snapshot identity exactly,
# maps to NEW UUIDs, and the newly-created Auth user's email matches the
# snapshot email. This is the safe rebind boundary.
AUTH_REFS="$WORKDIR/auth-refs.json"
jq '.auth_user_refs' "$SNAPSHOT" > "$AUTH_REFS"
jq '[.[] | {old_id,new_id}]' "$IDENTITY_MAP_FILE" > "$WORKDIR/id-map.json"
AUTH_COUNT="$(jq 'length' "$AUTH_REFS")"
jq -e --argjson n "$AUTH_COUNT" '
  length == $n and ([.[].old_id] | unique | length) == $n and
  ([.[].new_id] | unique | length) == $n and all(.[]; .old_id != .new_id)
' "$WORKDIR/id-map.json" >/dev/null || { echo "ERROR: identity map cardinality/uniqueness is invalid" >&2; exit 1; }

AUTH_B64="$(base64 -w0 "$AUTH_REFS")"
MAP_B64="$(base64 -w0 "$WORKDIR/id-map.json")"
BOUND_COUNT="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "
with refs as (
  select * from jsonb_to_recordset(convert_from(decode('${AUTH_B64}','base64'),'UTF8')::jsonb) as x(id text,email text)
), maps as (
  select * from jsonb_to_recordset(convert_from(decode('${MAP_B64}','base64'),'UTF8')::jsonb) as x(old_id text,new_id text)
)
select count(*) from refs r join maps m on m.old_id=r.id join auth.users u on u.id=m.new_id::uuid and lower(u.email)=lower(r.email); ")"
[ "$BOUND_COUNT" = "$AUTH_COUNT" ] || { echo "ERROR: prepared Auth identities do not exactly match snapshot identity references" >&2; exit 1; }

# Discover exactly which public columns are user identities from CURRENT schema
# FKs. This avoids brittle name guessing. We rewrite a child column iff its FK
# position references auth.users.id or household_members.user_id.
IDENTITY_COLUMNS="$WORKDIR/identity-columns.tsv"
psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -F $'\t' -c "
select 'public.'||child.relname, child_att.attname
from pg_constraint c
join pg_class child on child.oid=c.conrelid
join pg_namespace child_ns on child_ns.oid=child.relnamespace
join pg_class parent on parent.oid=c.confrelid
join pg_namespace parent_ns on parent_ns.oid=parent.relnamespace
join generate_subscripts(c.conkey,1) s(i) on true
join pg_attribute child_att on child_att.attrelid=c.conrelid and child_att.attnum=c.conkey[s.i]
join pg_attribute parent_att on parent_att.attrelid=c.confrelid and parent_att.attnum=c.confkey[s.i]
where c.contype='f' and child_ns.nspname='public'
  and ((parent_ns.nspname='auth' and parent.relname='users' and parent_att.attname='id')
    or (parent_ns.nspname='public' and parent.relname='household_members' and parent_att.attname='user_id'))
order by 1,2;" > "$IDENTITY_COLUMNS"
[ -s "$IDENTITY_COLUMNS" ] || { echo "ERROR: no schema-declared user FK columns were discovered" >&2; exit 1; }

MAP_OBJECT="$WORKDIR/map-object.json"
jq 'map({key:.old_id,value:.new_id}) | from_entries' "$WORKDIR/id-map.json" > "$MAP_OBJECT"

# Restore in reviewed dependency order. User FK values are rebound immediately
# before typed insertion; other UUID/domain data is preserved as snapshot JSON.
for table in "${TABLES[@]}"; do
  table_name="${table#public.}"
  COLS="$WORKDIR/cols-${table_name}.json"
  awk -F $'\t' -v t="$table" '$1==t {print $2}' "$IDENTITY_COLUMNS" | jq -Rsc 'split("\n") | map(select(length>0))' > "$COLS"
  TABLE_JSON="$WORKDIR/${table_name}.json"
  jq --arg table "$table" --slurpfile cols "$COLS" --slurpfile idmap "$MAP_OBJECT" '
    .tables[$table]
    | map(reduce ($cols[0][]) as $c (.;
        if .[$c] == null then .
        elif ($idmap[0][(.[$c] | tostring)] // null) == null then
          error("unmapped user identity in " + $table + "." + $c)
        else .[$c] = $idmap[0][(.[$c] | tostring)] end))
  ' "$SNAPSHOT" > "$TABLE_JSON"
  expected="$(jq 'length' "$TABLE_JSON")"
  [ "$expected" = "0" ] && continue
  TABLE_B64="$(base64 -w0 "$TABLE_JSON")"
  SQL_FILE="$WORKDIR/restore-${table_name}.sql"
  printf "insert into %s select * from jsonb_populate_recordset(null::%s, convert_from(decode('%s', 'base64'), 'UTF8')::jsonb);\n" "$table" "$table" "$TABLE_B64" > "$SQL_FILE"
  psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -q -f "$SQL_FILE"
done

# Count equality alone could miss a source field silently dropped by a newer
# schema. For every non-empty table, compare every source field after UUID
# rebinding with the restored row JSON. New target-only fields are ignored;
# all fields that existed in the recovery payload must survive identically.
for table in "${TABLES[@]}"; do
  table_name="${table#public.}"
  TABLE_JSON="$WORKDIR/${table_name}.json"
  expected="$(jq -r --arg table "$table" '.row_counts[$table]' "$SNAPSHOT")"
  actual="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select count(*) from ${table};")"
  [ "$actual" = "$expected" ] || { echo "ERROR: row-count mismatch for $table (expected=$expected actual=$actual)" >&2; exit 1; }
  [ "$expected" = "0" ] && continue

  KEYS_JSON="$WORKDIR/source-keys-${table_name}.json"
  jq '.[0] | keys' "$TABLE_JSON" > "$KEYS_JSON"
  KEYS_B64="$(base64 -w0 "$KEYS_JSON")"
  RESTORED_JSON="$WORKDIR/restored-${table_name}.json"
  psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "
with keys as (
  select value as key
  from jsonb_array_elements_text(convert_from(decode('${KEYS_B64}','base64'),'UTF8')::jsonb)
), restored as (
  select (
    select coalesce(jsonb_object_agg(k.key, to_jsonb(t)->k.key order by k.key), '{}'::jsonb)
    from keys k
  ) as row_json
  from ${table} t
)
select coalesce(jsonb_agg(row_json order by row_json::text), '[]'::jsonb)::text
from restored;" > "$RESTORED_JSON"

  SOURCE_CANONICAL="$WORKDIR/source-canonical-${table_name}.json"
  TARGET_CANONICAL="$WORKDIR/target-canonical-${table_name}.json"
  jq -S 'sort_by(to_entries | sort_by(.key) | map([.key,.value]) | tostring)' "$TABLE_JSON" > "$SOURCE_CANONICAL"
  jq -S 'sort_by(to_entries | sort_by(.key) | map([.key,.value]) | tostring)' "$RESTORED_JSON" > "$TARGET_CANONICAL"
  cmp -s "$SOURCE_CANONICAL" "$TARGET_CANONICAL" || {
    echo "ERROR: restored source-field content mismatch for $table" >&2
    exit 1
  }
done

AUTH_ORPHANS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select (select count(*) from public.household_members hm left join auth.users u on u.id=hm.user_id where u.id is null) + (select count(*) from public.profiles p left join auth.users u on u.id=p.user_id where u.id is null);")"
TASK_ORPHANS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select count(*) from public.task_instances ti left join public.households h on h.id=ti.household_id left join public.task_definitions td on td.id=ti.task_definition_id and td.household_id=ti.household_id where h.id is null or (ti.task_definition_id is not null and td.id is null);")"
SUBTASK_ORPHANS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select count(*) from public.task_subtask_instances si left join public.task_instances ti on ti.id=si.task_instance_id and ti.household_id=si.household_id where ti.id is null;")"
[ "$AUTH_ORPHANS" = "0" ] && [ "$TASK_ORPHANS" = "0" ] && [ "$SUBTASK_ORPHANS" = "0" ] || {
  echo "ERROR: restored household graph has identity/task linkage orphans" >&2; exit 1;
}

# Prove old production UUIDs no longer remain in any user-FK position.
OLD_IDS_SQL="$(jq -r '[.[].old_id | "'"'" + . + "'"'"] | join(",")' "$WORKDIR/id-map.json")"
while IFS=$'\t' read -r table column; do
  [ -n "$table" ] || continue
  stale="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select count(*) from ${table} where ${column}::text in (${OLD_IDS_SQL});")"
  [ "$stale" = "0" ] || { echo "ERROR: stale production user UUID remains in ${table}.${column}" >&2; exit 1; }
done < "$IDENTITY_COLUMNS"

HOUSEHOLDS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c 'select count(*) from public.households;')"
MEMBERS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c 'select count(*) from public.household_members;')"
TASKS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c 'select count(*) from public.task_instances;')"
SUBTASKS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c 'select count(*) from public.task_subtask_instances;')"
[ "$HOUSEHOLDS" -ge 1 ] && [ "$MEMBERS" -ge 1 ] && [ "$TASKS" -ge 1 ] || {
  echo "ERROR: restored foundational household data is unexpectedly empty" >&2; exit 1;
}

echo "Recovered household graph with Auth rebinding: households=${HOUSEHOLDS}, members=${MEMBERS}, tasks=${TASKS}, subtasks=${SUBTASKS}, identities=${AUTH_COUNT}"
echo "RESULT: PASS — typed household restore preserved all source fields with exact counts, constraints and old→new Auth UUID rebinding"
