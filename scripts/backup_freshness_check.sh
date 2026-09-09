#!/usr/bin/env bash
# CF-11 right-sized backup freshness check.
#
# Reads only metadata from the latest Family Ops snapshot stored in the
# existing separate app-save-hub Supabase project. It fails closed if the
# snapshot is missing, structurally invalid, belongs to another source
# project, or is older than MAX_BACKUP_AGE_HOURS.

set -euo pipefail

TARGET_PROJECT_REF="${TARGET_PROJECT_REF:-wdwbmvpipbdpomqulsrj}"
SOURCE_PROJECT_REF="${SOURCE_PROJECT_REF:-dnlqxjpjpkxnfgculzip}"
MAX_BACKUP_AGE_HOURS="${MAX_BACKUP_AGE_HOURS:-26}"

for cmd in curl jq date; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command '$cmd' is missing" >&2; exit 2; }
done
if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  echo "ERROR: SUPABASE_ACCESS_TOKEN is required" >&2
  exit 2
fi
if ! [[ "$MAX_BACKUP_AGE_HOURS" =~ ^[0-9]+$ ]] || [ "$MAX_BACKUP_AGE_HOURS" -le 0 ]; then
  echo "ERROR: MAX_BACKUP_AGE_HOURS must be a positive integer" >&2
  exit 2
fi

SQL="select updated_at, payload->>'created_at' as source_created_at, payload->>'source_project_ref' as source_project_ref, payload->>'schema_version' as schema_version, jsonb_typeof(payload->'tables') as tables_type, coalesce((payload->'row_counts'->>'public.households')::bigint, 0) as households, coalesce((payload->'row_counts'->>'public.household_members')::bigint, 0) as household_members, coalesce((payload->'row_counts'->>'public.task_instances')::bigint, 0) as task_instances from public.app_saves where app_id='family-ops' and slot_id='household' order by updated_at desc limit 1;"

RESPONSE="$(mktemp)"
trap 'rm -f "$RESPONSE"' EXIT
jq -n --arg query "$SQL" '{query: $query}' \
  | curl --fail-with-body --silent --show-error \
      -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
      -H 'Content-Type: application/json' \
      -d @- \
      "https://api.supabase.com/v1/projects/${TARGET_PROJECT_REF}/database/query" \
      > "$RESPONSE" || {
        echo "ALERT: could not read Family Ops recovery snapshot metadata from app-save-hub" >&2
        exit 1
      }

if ! jq -e --arg source "$SOURCE_PROJECT_REF" '
  length == 1 and
  .[0].source_project_ref == $source and
  .[0].schema_version == "1" and
  .[0].tables_type == "object" and
  (.[0].households | tonumber) >= 1 and
  (.[0].household_members | tonumber) >= 1 and
  (.[0].task_instances | tonumber) >= 1
' "$RESPONSE" >/dev/null; then
  echo "ALERT: latest Family Ops recovery snapshot is missing or structurally invalid" >&2
  exit 1
fi

SNAPSHOT_TIMESTAMP="$(jq -r '.[0].source_created_at' "$RESPONSE")"
STORED_TIMESTAMP="$(jq -r '.[0].updated_at' "$RESPONSE")"
SNAPSHOT_EPOCH="$(date -u -d "$SNAPSHOT_TIMESTAMP" +%s 2>/dev/null || true)"
STORED_EPOCH="$(date -u -d "$STORED_TIMESTAMP" +%s 2>/dev/null || true)"
if [ -z "$SNAPSHOT_EPOCH" ] || [ -z "$STORED_EPOCH" ]; then
  echo "ALERT: latest recovery snapshot has an unparsable timestamp" >&2
  exit 1
fi

NOW_EPOCH="$(date -u +%s)"
for value in "$SNAPSHOT_EPOCH" "$STORED_EPOCH"; do
  if [ "$value" -gt $((NOW_EPOCH + 300)) ]; then
    echo "ALERT: recovery snapshot timestamp is unexpectedly in the future" >&2
    exit 1
  fi
done

AGE_SECONDS=$((NOW_EPOCH - SNAPSHOT_EPOCH))
if [ "$AGE_SECONDS" -lt 0 ]; then AGE_SECONDS=0; fi
MAX_AGE_SECONDS=$((MAX_BACKUP_AGE_HOURS * 3600))
AGE_HOURS=$((AGE_SECONDS / 3600))
AGE_MINUTES=$(((AGE_SECONDS % 3600) / 60))

echo "Latest Family Ops recovery snapshot age: ${AGE_HOURS}h ${AGE_MINUTES}m (threshold: ${MAX_BACKUP_AGE_HOURS}h)"
if [ "$AGE_SECONDS" -gt "$MAX_AGE_SECONDS" ]; then
  echo "ALERT: latest Family Ops recovery snapshot exceeds the freshness threshold" >&2
  exit 1
fi

echo "RESULT: PASS — separate-project household snapshot is present, structurally valid and fresh"
