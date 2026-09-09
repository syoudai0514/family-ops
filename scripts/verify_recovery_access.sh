#!/usr/bin/env bash
# Prove that recovered users can actually resume Family Ops through normal
# authenticated Supabase/PostgREST access after Auth UUID rebinding.
#
# This is stronger than DB row-count proof: every signed-in identity produced by
# prepare_recovery_auth_smoke.sh must be able to read its profile, household
# membership, household and at least one household task through RLS.

set -euo pipefail

SESSION_FILE=""
usage() {
  cat <<'USAGE'
Usage: scripts/verify_recovery_access.sh --session-file <path>

Required env:
  API_URL   Disposable Supabase API URL
  ANON_KEY  Disposable Supabase anon key
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --session-file)
      [ $# -ge 2 ] || { echo "ERROR: --session-file requires a value" >&2; exit 2; }
      SESSION_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[ -s "$SESSION_FILE" ] || { echo "ERROR: --session-file is required and must be non-empty" >&2; exit 2; }
for v in API_URL ANON_KEY; do
  [ -n "${!v:-}" ] || { echo "ERROR: required env var $v is missing" >&2; exit 2; }
done
for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command '$cmd' is missing" >&2; exit 2; }
done

COUNT="$(jq 'length' "$SESSION_FILE")"
[ "$COUNT" -ge 1 ] || { echo "ERROR: recovery session file contains no identities" >&2; exit 1; }

get_json() {
  local path="$1"
  local token="$2"
  curl --fail-with-body --silent --show-error \
    -H "apikey: ${ANON_KEY}" \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/json' \
    "${API_URL}/rest/v1/${path}"
}

for ((i=0; i<COUNT; i++)); do
  NEW_ID="$(jq -er ".[$i].new_id" "$SESSION_FILE")"
  TOKEN="$(jq -er ".[$i].access_token" "$SESSION_FILE")"

  PROFILE="$(get_json "profiles?user_id=eq.${NEW_ID}&select=user_id&limit=1" "$TOKEN")"
  jq -e --arg id "$NEW_ID" 'length == 1 and .[0].user_id == $id' <<<"$PROFILE" >/dev/null || {
    echo "ERROR: recovered signed-in identity cannot read its profile through RLS" >&2; exit 1;
  }

  MEMBERSHIP="$(get_json "household_members?user_id=eq.${NEW_ID}&select=user_id,household_id&limit=1" "$TOKEN")"
  jq -e --arg id "$NEW_ID" 'length == 1 and .[0].user_id == $id and (. [0].household_id | length) > 0' <<<"$MEMBERSHIP" >/dev/null || {
    echo "ERROR: recovered signed-in identity cannot read its household membership through RLS" >&2; exit 1;
  }
  HOUSEHOLD_ID="$(jq -er '.[0].household_id' <<<"$MEMBERSHIP")"

  HOUSEHOLD="$(get_json "households?id=eq.${HOUSEHOLD_ID}&select=id&limit=1" "$TOKEN")"
  jq -e --arg id "$HOUSEHOLD_ID" 'length == 1 and .[0].id == $id' <<<"$HOUSEHOLD" >/dev/null || {
    echo "ERROR: recovered signed-in identity cannot read its restored household through RLS" >&2; exit 1;
  }

  TASK="$(get_json "task_instances?household_id=eq.${HOUSEHOLD_ID}&select=id,household_id&limit=1" "$TOKEN")"
  jq -e --arg id "$HOUSEHOLD_ID" 'length >= 1 and .[0].household_id == $id' <<<"$TASK" >/dev/null || {
    echo "ERROR: recovered signed-in identity cannot read restored household task data through RLS" >&2; exit 1;
  }

  unset TOKEN PROFILE MEMBERSHIP HOUSEHOLD TASK NEW_ID HOUSEHOLD_ID
 done

echo "Authenticated recovery access verified for ${COUNT} recovered identity/identities."
echo "RESULT: PASS — signed-in recovered users can reach profile, membership, household and task data through normal RLS"
