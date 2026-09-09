#!/usr/bin/env bash
# CF-11 right-sized backup freshness check.
# Reads only the reserved Family Ops owner/app/slot namespace in app-save-hub.

set -euo pipefail

TARGET_PROJECT_REF="${TARGET_PROJECT_REF:-wdwbmvpipbdpomqulsrj}"
SOURCE_PROJECT_REF="${SOURCE_PROJECT_REF:-dnlqxjpjpkxnfgculzip}"
MAX_BACKUP_AGE_HOURS="${MAX_BACKUP_AGE_HOURS:-26}"
APP_ID="family-ops-recovery-v1"
SLOT_ID="household-durable-v1"

for cmd in curl jq date; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command '$cmd' is missing" >&2; exit 2; }
done
[ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || { echo "ERROR: SUPABASE_ACCESS_TOKEN is required" >&2; exit 2; }
if ! [[ "$MAX_BACKUP_AGE_HOURS" =~ ^[0-9]+$ ]] || [ "$MAX_BACKUP_AGE_HOURS" -le 0 ]; then
  echo "ERROR: MAX_BACKUP_AGE_HOURS must be a positive integer" >&2; exit 2
fi

SQL="select updated_at, payload->>'created_at' as source_created_at, payload->>'source_project_ref' as source_project_ref, payload->>'schema_version' as schema_version, payload->'recovery_namespace'->>'app_id' as namespace_app_id, payload->'recovery_namespace'->>'slot_id' as namespace_slot_id, jsonb_typeof(payload->'tables') as tables_type, coalesce((payload->'row_counts'->>'public.households')::bigint,0) as households, coalesce((payload->'row_counts'->>'public.household_members')::bigint,0) as household_members, coalesce((payload->'row_counts'->>'public.task_instances')::bigint,0) as task_instances from public.app_saves where user_id=(select id from auth.users order by created_at nulls last,id limit 1) and app_id='${APP_ID}' and slot_id='${SLOT_ID}' limit 1;"

RESPONSE="$(mktemp)"
trap 'rm -f "$RESPONSE"' EXIT
jq -n --arg query "$SQL" '{query:$query}' \
  | curl --fail-with-body --silent --show-error \
      -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
      -H 'Content-Type: application/json' -d @- \
      "https://api.supabase.com/v1/projects/${TARGET_PROJECT_REF}/database/query" > "$RESPONSE" || {
        echo "ALERT: could not read Family Ops recovery snapshot metadata from app-save-hub" >&2; exit 1;
      }

if ! jq -e --arg source "$SOURCE_PROJECT_REF" --arg app "$APP_ID" --arg slot "$SLOT_ID" '
  length == 1 and .[0].source_project_ref == $source and .[0].schema_version == "1" and
  .[0].namespace_app_id == $app and .[0].namespace_slot_id == $slot and
  .[0].tables_type == "object" and (.[0].households|tonumber) >= 1 and
  (.[0].household_members|tonumber) >= 1 and (.[0].task_instances|tonumber) >= 1
' "$RESPONSE" >/dev/null; then
  echo "ALERT: latest Family Ops recovery snapshot is missing or structurally invalid" >&2; exit 1
fi

SNAPSHOT_TIMESTAMP="$(jq -r '.[0].source_created_at' "$RESPONSE")"
STORED_TIMESTAMP="$(jq -r '.[0].updated_at' "$RESPONSE")"
SNAPSHOT_EPOCH="$(date -u -d "$SNAPSHOT_TIMESTAMP" +%s 2>/dev/null || true)"
STORED_EPOCH="$(date -u -d "$STORED_TIMESTAMP" +%s 2>/dev/null || true)"
[ -n "$SNAPSHOT_EPOCH" ] && [ -n "$STORED_EPOCH" ] || { echo "ALERT: latest recovery snapshot has an unparsable timestamp" >&2; exit 1; }

NOW_EPOCH="$(date -u +%s)"
for value in "$SNAPSHOT_EPOCH" "$STORED_EPOCH"; do
  [ "$value" -le $((NOW_EPOCH + 300)) ] || { echo "ALERT: recovery snapshot timestamp is unexpectedly in the future" >&2; exit 1; }
done
AGE_SECONDS=$((NOW_EPOCH - SNAPSHOT_EPOCH)); [ "$AGE_SECONDS" -ge 0 ] || AGE_SECONDS=0
MAX_AGE_SECONDS=$((MAX_BACKUP_AGE_HOURS * 3600))
AGE_HOURS=$((AGE_SECONDS / 3600)); AGE_MINUTES=$(((AGE_SECONDS % 3600) / 60))
echo "Latest isolated Family Ops recovery snapshot age: ${AGE_HOURS}h ${AGE_MINUTES}m (threshold: ${MAX_BACKUP_AGE_HOURS}h)"
[ "$AGE_SECONDS" -le "$MAX_AGE_SECONDS" ] || { echo "ALERT: latest Family Ops recovery snapshot exceeds the freshness threshold" >&2; exit 1; }

echo "RESULT: PASS — reserved owner/app/slot snapshot is present, structurally valid and fresh"
