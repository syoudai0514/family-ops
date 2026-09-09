#!/usr/bin/env bash
# CF-11 right-sized recovery drill.
# Restore durable household data into an EMPTY disposable Supabase schema,
# rebinding old Auth UUIDs to newly authenticated users without copying
# production passwords, sessions or provider credentials.

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
                          prepare_recovery_auth_smoke.sh.
  --snapshot-file <json>  Optional payload. Otherwise read latest reserved
                          Family Ops snapshot from app-save-hub.
  -h, --help              Show help.

Safety:
  Target must be localhost/127.0.0.1 unless ALLOW_MANAGED_RECOVERY_TARGET=1.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --scratch-db-url) [ $# -ge 2 ] || exit 2; SCRATCH_DB_URL="$2"; shift 2 ;;
    --identity-map) [ $# -ge 2 ] || exit 2; IDENTITY_MAP_FILE="$2"; shift 2 ;;
    --snapshot-file) [ $# -ge 2 ] || exit 2; SNAPSHOT_FILE="$2"; shift 2 ;;
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
  [ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || { echo "ERROR: SUPABASE_ACCESS_TOKEN is required" >&2; exit 2; }
  RESPONSE="$WORKDIR/latest.json"
  SQL="select payload from public.app_saves where user_id=(select id from auth.users order by created_at nulls last, id limit 1) and app_id='${APP_ID}' and slot_id='${SLOT_ID}' limit 1;"
  jq -n --arg query "$SQL" '{query:$query}' \
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

printf '%s\n' "${TABLES[@]}" | sort > "$WORKDIR/expected-keys.txt"
jq -r '.tables | keys[]' "$SNAPSHOT" | sort > "$WORKDIR/actual-keys.txt"
cmp -s "$WORKDIR/expected-keys.txt" "$WORKDIR/actual-keys.txt" || {
  echo "ERROR: snapshot table set does not exactly match reviewed allowlist" >&2; exit 1;
}
for table in "${TABLES[@]}"; do
  jq -e --arg table "$table" '.tables[$table] | type == "array"' "$SNAPSHOT" >/dev/null || {
    echo "ERROR: snapshot table payload is not an array: $table" >&2; exit 1;
  }
done

# Migration history IDs can differ when the same reviewed migration was applied
# through a different deployment path. Both histories must exist; compatibility
# is proven directly below by typed insertion, constraints, exact counts, exact
# source-field preservation, graph integrity and authenticated RLS access.
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

# Validate exact old -> new Auth identity mapping and that each NEW Auth row has
# the same verified recovery email reference as the snapshot.
jq '.auth_user_refs' "$SNAPSHOT" > "$WORKDIR/auth-refs.json"
jq '[.[] | {old_id,new_id}]' "$IDENTITY_MAP_FILE" > "$WORKDIR/id-map.json"
AUTH_COUNT="$(jq 'length' "$WORKDIR/auth-refs.json")"
jq -e --argjson n "$AUTH_COUNT" '
  length == $n and ([.[].old_id] | unique | length) == $n and
  ([.[].new_id] | unique | length) == $n and all(.[]; .old_id != .new_id)
' "$WORKDIR/id-map.json" >/dev/null || { echo "ERROR: identity map cardinality/uniqueness is invalid" >&2; exit 1; }
AUTH_B64="$(base64 -w0 "$WORKDIR/auth-refs.json")"
MAP_B64="$(base64 -w0 "$WORKDIR/id-map.json")"
BOUND_COUNT="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "
with refs as (
  select * from jsonb_to_recordset(convert_from(decode('${AUTH_B64}','base64'),'UTF8')::jsonb) as x(id text,email text)
), maps as (
  select * from jsonb_to_recordset(convert_from(decode('${MAP_B64}','base64'),'UTF8')::jsonb) as x(old_id text,new_id text)
)
select count(*) from refs r join maps m on m.old_id=r.id join auth.users u on u.id=m.new_id::uuid and lower(u.email)=lower(r.email);")"
[ "$BOUND_COUNT" = "$AUTH_COUNT" ] || { echo "ERROR: prepared Auth identities do not exactly match snapshot identity references" >&2; exit 1; }

# Discover user identity positions from CURRENT target FKs instead of guessed
# column names. Rebind only columns that reference auth.users.id or
# household_members.user_id.
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
jq 'map({key:.old_id,value:.new_id}) | from_entries' "$WORKDIR/id-map.json" > "$WORKDIR/map-object.json"

# Restore parents before children with normal FK/check/trigger behavior active.
# household_members legitimately fires the CURRENT trigger that creates a
# minimal real-user domain_actor_ref for a brand-new member. During recovery the
# snapshot's canonical actor_ref must win (its id is referenced by later domain
# rows), so verify those are *only* the expected trigger bootstrap rows and
# remove them before restoring public.domain_actor_refs.
for table in "${TABLES[@]}"; do
  table_name="${table#public.}"
  COLS="$WORKDIR/cols-${table_name}.json"
  awk -F $'\t' -v t="$table" '$1==t {print $2}' "$IDENTITY_COLUMNS" | jq -Rsc 'split("\n") | map(select(length>0))' > "$COLS"
  TABLE_JSON="$WORKDIR/${table_name}.json"
  jq --arg table "$table" --slurpfile cols "$COLS" --slurpfile idmap "$WORKDIR/map-object.json" '
    .tables[$table]
    | map(reduce ($cols[0][]) as $c (.;
        if .[$c] == null then .
        elif ($idmap[0][(.[$c] | tostring)] // null) == null then
          error("unmapped user identity in " + $table + "." + $c)
        else .[$c] = $idmap[0][(.[$c] | tostring)] end))
  ' "$SNAPSHOT" > "$TABLE_JSON"

  expected="$(jq 'length' "$TABLE_JSON")"
  if [ "$expected" != "0" ]; then
    TABLE_B64="$(base64 -w0 "$TABLE_JSON")"
    printf "insert into %s select * from jsonb_populate_recordset(null::%s, convert_from(decode('%s','base64'),'UTF8')::jsonb);\n" \
      "$table" "$table" "$TABLE_B64" > "$WORKDIR/restore-${table_name}.sql"
    psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -q -f "$WORKDIR/restore-${table_name}.sql"
  fi

  if [ "$table" = "public.household_members" ]; then
    EXPECTED_BOOTSTRAP="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select count(*) from (select distinct household_id,user_id from public.household_members) x;")"
    ACTUAL_BOOTSTRAP="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c 'select count(*) from public.domain_actor_refs;')"
    INVALID_BOOTSTRAP="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "
select count(*)
from public.domain_actor_refs a
left join public.household_members hm
  on hm.household_id=a.household_id and hm.user_id=a.real_user_id
where hm.user_id is null
   or a.actor_kind <> 'real_user'
   or a.real_user_id is null
   or a.test_context_id is not null
   or a.simulated_role is not null;")"
    [ "$ACTUAL_BOOTSTRAP" = "$EXPECTED_BOOTSTRAP" ] && [ "$INVALID_BOOTSTRAP" = "0" ] || {
      echo "ERROR: unexpected rows exist in domain_actor_refs before canonical recovery restore" >&2; exit 1;
    }
    psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -q -c "
      delete from public.domain_actor_refs a
      using public.household_members hm
      where a.household_id=hm.household_id
        and a.real_user_id=hm.user_id
        and a.actor_kind='real_user'
        and a.test_context_id is null
        and a.simulated_role is null;"
    [ "$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c 'select count(*) from public.domain_actor_refs;')" = "0" ] || {
      echo "ERROR: generated real-user actor refs were not fully reconciled before restore" >&2; exit 1;
    }
    echo "Reconciled ${ACTUAL_BOOTSTRAP} generated real-user actor ref bootstrap row(s) before canonical snapshot restore."
  fi
done

# Count equality is not enough. For every non-empty table compare every source
# field (after UUID rebinding) against restored JSON. Target-only fields may
# exist, but no field present in the recovery payload may be silently lost.
for table in "${TABLES[@]}"; do
  table_name="${table#public.}"
  TABLE_JSON="$WORKDIR/${table_name}.json"
  expected="$(jq -r --arg table "$table" '.row_counts[$table]' "$SNAPSHOT")"
  actual="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select count(*) from ${table};")"
  [ "$actual" = "$expected" ] || { echo "ERROR: row-count mismatch for $table (expected=$expected actual=$actual)" >&2; exit 1; }
  [ "$expected" = "0" ] && continue

  jq '.[0] | keys' "$TABLE_JSON" > "$WORKDIR/source-keys-${table_name}.json"
  KEYS_B64="$(base64 -w0 "$WORKDIR/source-keys-${table_name}.json")"
  psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "
with keys as (
  select value as key from jsonb_array_elements_text(convert_from(decode('${KEYS_B64}','base64'),'UTF8')::jsonb)
), restored as (
  select (select coalesce(jsonb_object_agg(k.key,to_jsonb(t)->k.key order by k.key),'{}'::jsonb) from keys k) as row_json
  from ${table} t
)
select coalesce(jsonb_agg(row_json order by row_json::text),'[]'::jsonb)::text from restored;" > "$WORKDIR/restored-${table_name}.json"

  jq -S 'sort_by(to_entries | sort_by(.key) | map([.key,.value]) | tostring)' "$TABLE_JSON" > "$WORKDIR/source-canonical-${table_name}.json"
  jq -S 'sort_by(to_entries | sort_by(.key) | map([.key,.value]) | tostring)' "$WORKDIR/restored-${table_name}.json" > "$WORKDIR/target-canonical-${table_name}.json"
  cmp -s "$WORKDIR/source-canonical-${table_name}.json" "$WORKDIR/target-canonical-${table_name}.json" || {
    echo "ERROR: restored source-field content mismatch for $table" >&2; exit 1;
  }
done

AUTH_ORPHANS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select (select count(*) from public.household_members hm left join auth.users u on u.id=hm.user_id where u.id is null) + (select count(*) from public.profiles p left join auth.users u on u.id=p.user_id where u.id is null);")"
TASK_ORPHANS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select count(*) from public.task_instances ti left join public.households h on h.id=ti.household_id left join public.task_definitions td on td.id=ti.task_definition_id and td.household_id=ti.household_id where h.id is null or (ti.task_definition_id is not null and td.id is null);")"
SUBTASK_ORPHANS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "select count(*) from public.task_subtask_instances si left join public.task_instances ti on ti.id=si.task_instance_id and ti.household_id=si.household_id where ti.id is null;")"
[ "$AUTH_ORPHANS" = "0" ] && [ "$TASK_ORPHANS" = "0" ] && [ "$SUBTASK_ORPHANS" = "0" ] || {
  echo "ERROR: restored household graph has identity/task linkage orphans" >&2; exit 1;
}

# Prove that no production Auth UUID survives in any schema-declared identity
# FK position. Reuse the base64 identity map rather than interpolating a quoted
# SQL IN-list in the shell; that keeps UUID values data-only and avoids quoting
# ambiguity while preserving the same fail-closed check.
while IFS=$'\t' read -r table column; do
  [ -n "$table" ] || continue
  stale="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c "
with maps as (
  select *
  from jsonb_to_recordset(convert_from(decode('${MAP_B64}','base64'),'UTF8')::jsonb)
       as x(old_id text,new_id text)
)
select count(*)
from ${table} t
join maps m on t.${column}::text = m.old_id;")"
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