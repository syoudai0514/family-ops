#!/usr/bin/env bash
# Create the right-sized CF-11 household recovery snapshot.
#
# This uses only services Family Ops already has:
# - the existing GitHub Actions SUPABASE_ACCESS_TOKEN
# - the Family Ops production Supabase project
# - the separate existing app-save-hub Supabase project used by ManaEvo
#
# No Cloudflare R2, age key, DB password, provider credential, queue, or cron
# state is required. The snapshot is intentionally limited to durable
# household/domain data listed in family_ops_recovery_tables.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLES_FILE="${RECOVERY_TABLES_FILE:-$ROOT/scripts/family_ops_recovery_tables.txt}"
SOURCE_PROJECT_REF="${SOURCE_PROJECT_REF:-dnlqxjpjpkxnfgculzip}"
TARGET_PROJECT_REF="${TARGET_PROJECT_REF:-wdwbmvpipbdpomqulsrj}"
MAX_BACKUPS="${MAX_BACKUPS:-30}"
APP_ID="family-ops"
SLOT_ID="household"
SCHEMA_VERSION=1

for cmd in curl jq base64 cmp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command '$cmd' is missing" >&2; exit 2; }
done

if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  echo "ERROR: SUPABASE_ACCESS_TOKEN is required" >&2
  exit 2
fi
if [ "$SOURCE_PROJECT_REF" = "$TARGET_PROJECT_REF" ]; then
  echo "ERROR: recovery snapshot target must be a separate Supabase project" >&2
  exit 2
fi
if ! [[ "$MAX_BACKUPS" =~ ^[0-9]+$ ]] || [ "$MAX_BACKUPS" -lt 2 ] || [ "$MAX_BACKUPS" -gt 365 ]; then
  echo "ERROR: MAX_BACKUPS must be an integer between 2 and 365" >&2
  exit 2
fi
if [ ! -s "$TABLES_FILE" ]; then
  echo "ERROR: recovery table allowlist is missing or empty: $TABLES_FILE" >&2
  exit 2
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

api_query_file() {
  local project_ref="$1"
  local sql_file="$2"
  local output_file="$3"
  jq -Rs '{query: .}' "$sql_file" \
    | curl --fail-with-body --silent --show-error \
        -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d @- \
        "https://api.supabase.com/v1/projects/${project_ref}/database/query" \
        > "$output_file"
}

api_query() {
  local project_ref="$1"
  local sql="$2"
  local output_file="$3"
  local sql_file="$WORKDIR/query.sql"
  printf '%s\n' "$sql" > "$sql_file"
  api_query_file "$project_ref" "$sql_file" "$output_file"
}

mapfile -t TABLES < <(sed -E 's/[[:space:]]+#.*$//' "$TABLES_FILE" | sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d')
if [ "${#TABLES[@]}" -eq 0 ]; then
  echo "ERROR: recovery table allowlist contains no tables" >&2
  exit 2
fi
for table in "${TABLES[@]}"; do
  if ! [[ "$table" =~ ^public\.[a-z][a-z0-9_]*$ ]]; then
    echo "ERROR: invalid recovery table identifier: $table" >&2
    exit 2
  fi
done
if [ "$(printf '%s\n' "${TABLES[@]}" | sort | uniq -d | wc -l)" -ne 0 ]; then
  echo "ERROR: recovery table allowlist contains duplicates" >&2
  exit 2
fi

# The snapshot carries only a minimal Auth mapping reference (old UUID/email)
# for operator-assisted recovery. Passwords, OAuth identities, sessions and
# tokens are never copied to app-save-hub.
MIGRATION_RESPONSE="$WORKDIR/migration.json"
api_query "$SOURCE_PROJECT_REF" \
  "select version from supabase_migrations.schema_migrations order by version desc limit 1;" \
  "$MIGRATION_RESPONSE"
MIGRATION_VERSION="$(jq -er '.[0].version | tostring' "$MIGRATION_RESPONSE")"

AUTH_RESPONSE="$WORKDIR/auth-refs.json"
api_query "$SOURCE_PROJECT_REF" \
  "select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'email', u.email) order by u.id), '[]'::jsonb) as rows from auth.users u where exists (select 1 from public.household_members hm where hm.user_id = u.id);" \
  "$AUTH_RESPONSE"

SNAPSHOT="$WORKDIR/snapshot.json"
jq -n \
  --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg source_project_ref "$SOURCE_PROJECT_REF" \
  --arg source_git_sha "${GITHUB_SHA:-unknown}" \
  --arg source_migration_version "$MIGRATION_VERSION" \
  --slurpfile auth "$AUTH_RESPONSE" \
  '{
    schema_version: 1,
    created_at: $created_at,
    source_project_ref: $source_project_ref,
    source_git_sha: $source_git_sha,
    source_migration_version: $source_migration_version,
    restore_scope: "durable-household-domain",
    auth_user_refs: ($auth[0][0].rows // []),
    tables: {}
  }' > "$SNAPSHOT"

for table in "${TABLES[@]}"; do
  table_name="${table#public.}"
  META_RESPONSE="$WORKDIR/meta-${table_name}.json"
  api_query "$SOURCE_PROJECT_REF" \
    "select to_regclass('${table}') is not null as table_exists, exists (select 1 from information_schema.columns where table_schema='public' and table_name='${table_name}' and column_name='test_context_id') as has_test_context;" \
    "$META_RESPONSE"

  if ! jq -e 'length == 1 and .[0].table_exists == true' "$META_RESPONSE" >/dev/null; then
    echo "ERROR: recovery allowlist table is missing in source schema: $table" >&2
    exit 1
  fi

  filter=""
  if [ "$(jq -r '.[0].has_test_context' "$META_RESPONSE")" = "true" ]; then
    filter=" where t.test_context_id is null"
  fi

  ROW_RESPONSE="$WORKDIR/rows-${table_name}.json"
  api_query "$SOURCE_PROJECT_REF" \
    "select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text), '[]'::jsonb) as rows from ${table} t${filter};" \
    "$ROW_RESPONSE"

  NEXT="$WORKDIR/snapshot-next.json"
  jq --arg table "$table" --slurpfile response "$ROW_RESPONSE" \
    '.tables[$table] = ($response[0][0].rows // [])' "$SNAPSHOT" > "$NEXT"
  mv "$NEXT" "$SNAPSHOT"
done

NEXT="$WORKDIR/snapshot-final.json"
jq '.row_counts = (.tables | with_entries(.value |= length))' "$SNAPSHOT" > "$NEXT"
mv "$NEXT" "$SNAPSHOT"

# A snapshot that cannot even represent the currently used household/task
# backbone is not a valid successful backup.
jq -e '
  .schema_version == 1 and
  (.auth_user_refs | length) >= 1 and
  .row_counts["public.households"] >= 1 and
  .row_counts["public.profiles"] >= 1 and
  .row_counts["public.household_members"] >= 1 and
  .row_counts["public.task_definitions"] >= 1 and
  .row_counts["public.task_instances"] >= 1
' "$SNAPSHOT" >/dev/null || {
  echo "ERROR: source snapshot failed foundational household-data checks" >&2
  exit 1
}

# app-save-hub is an existing personal save project. Validate the exact
# contract we rely on instead of silently creating or changing its schema.
TARGET_PREFLIGHT="$WORKDIR/target-preflight.json"
api_query "$TARGET_PROJECT_REF" \
  "select (select count(*) from auth.users) as auth_user_count, to_regclass('public.app_saves') is not null as app_saves_exists, to_regclass('public.app_save_backups') is not null as app_save_backups_exists, (select count(*) from information_schema.columns where table_schema='public' and table_name='app_saves' and column_name in ('user_id','app_id','slot_id','revision','schema_version','payload','updated_at')) = 7 as app_saves_contract, (select count(*) from information_schema.columns where table_schema='public' and table_name='app_save_backups' and column_name in ('id','user_id','app_id','slot_id','revision','schema_version','reason','payload','created_at')) = 9 as app_save_backups_contract;" \
  "$TARGET_PREFLIGHT"

jq -e '
  length == 1 and
  .[0].auth_user_count == 1 and
  .[0].app_saves_exists == true and
  .[0].app_save_backups_exists == true and
  .[0].app_saves_contract == true and
  .[0].app_save_backups_contract == true
' "$TARGET_PREFLIGHT" >/dev/null || {
  echo "ERROR: app-save-hub does not match the reviewed personal-save contract" >&2
  exit 1
}

# Base64 is used only as a safe SQL transport encoding for the JSON payload;
# it is NOT encryption and is never written to logs/artifacts.
SNAPSHOT_B64="$WORKDIR/snapshot.b64"
base64 -w0 "$SNAPSHOT" > "$SNAPSHOT_B64"
TARGET_SQL="$WORKDIR/store.sql"
cat > "$TARGET_SQL" <<'SQL'
with owner as (
  select id from auth.users order by created_at nulls last, id limit 1
), payload as (
  select convert_from(decode('
SQL
cat "$SNAPSHOT_B64" >> "$TARGET_SQL"
cat >> "$TARGET_SQL" <<SQL
', 'base64'), 'UTF8')::jsonb as value
), next_revision as (
  select coalesce(max(revision), 0) + 1 as revision
  from public.app_save_backups
  where app_id = '${APP_ID}' and slot_id = '${SLOT_ID}'
), inserted as (
  insert into public.app_save_backups
    (id, user_id, app_id, slot_id, revision, schema_version, reason, payload, created_at)
  select gen_random_uuid(), owner.id, '${APP_ID}', '${SLOT_ID}', next_revision.revision,
         ${SCHEMA_VERSION}, 'daily_household_snapshot', payload.value, now()
  from owner, payload, next_revision
  returning id, user_id, revision, created_at
), current_save as (
  insert into public.app_saves
    (user_id, app_id, slot_id, revision, schema_version, payload, updated_at)
  select inserted.user_id, '${APP_ID}', '${SLOT_ID}', inserted.revision,
         ${SCHEMA_VERSION}, payload.value, inserted.created_at
  from inserted, payload
  on conflict (user_id, app_id, slot_id) do update
    set revision = excluded.revision,
        schema_version = excluded.schema_version,
        payload = excluded.payload,
        updated_at = excluded.updated_at
  returning revision, updated_at
), pruned as (
  delete from public.app_save_backups b
  where b.id in (
    select id
    from public.app_save_backups
    where app_id = '${APP_ID}' and slot_id = '${SLOT_ID}'
    order by created_at desc, revision desc
    offset ${MAX_BACKUPS}
  )
  returning id
)
select inserted.id as backup_id,
       inserted.revision,
       inserted.created_at,
       (select count(*) from pruned) as pruned_count
from inserted;
SQL

STORE_RESPONSE="$WORKDIR/store-response.json"
api_query_file "$TARGET_PROJECT_REF" "$TARGET_SQL" "$STORE_RESPONSE"
jq -e 'length == 1 and (.[0].revision | tonumber) >= 1 and (.[0].backup_id | length) > 0' "$STORE_RESPONSE" >/dev/null || {
  echo "ERROR: app-save-hub did not confirm a stored Family Ops snapshot" >&2
  exit 1
}

# Read the current copy back from the separate project and compare the full
# JSONB payload. PASS therefore proves both write and independent retrieval,
# not merely a successful HTTP status.
VERIFY_RESPONSE="$WORKDIR/verify.json"
api_query "$TARGET_PROJECT_REF" \
  "select revision, updated_at, payload from public.app_saves where app_id='${APP_ID}' and slot_id='${SLOT_ID}' order by updated_at desc limit 1;" \
  "$VERIFY_RESPONSE"
jq -e 'length == 1 and .[0].payload.schema_version == 1 and .[0].payload.source_project_ref == "dnlqxjpjpkxnfgculzip"' "$VERIFY_RESPONSE" >/dev/null || {
  echo "ERROR: stored current snapshot metadata is invalid" >&2
  exit 1
}

jq -S . "$SNAPSHOT" > "$WORKDIR/source-canonical.json"
jq -S '.[0].payload' "$VERIFY_RESPONSE" > "$WORKDIR/target-canonical.json"
cmp -s "$WORKDIR/source-canonical.json" "$WORKDIR/target-canonical.json" || {
  echo "ERROR: snapshot read-back differs from the source household payload" >&2
  exit 1
}

REVISION="$(jq -r '.[0].revision' "$STORE_RESPONSE")"
CREATED_AT="$(jq -r '.[0].created_at' "$STORE_RESPONSE")"
TABLE_COUNT="${#TABLES[@]}"
TOTAL_ROWS="$(jq '[.row_counts[]] | add' "$SNAPSHOT")"
echo "Stored Family Ops recovery snapshot: revision=${REVISION}, tables=${TABLE_COUNT}, rows=${TOTAL_ROWS}, at=${CREATED_AT}"
echo "RESULT: PASS — household snapshot stored and read back from separate app-save-hub Supabase project"
