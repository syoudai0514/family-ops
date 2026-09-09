#!/usr/bin/env bash
# Prepare real Auth identities in a disposable Supabase recovery target.
#
# This deliberately does NOT restore passwords/sessions/OAuth identities from
# production. For every identity reference in the latest household snapshot it:
#   1. creates a NEW confirmed local Auth user with the same email;
#   2. signs in through GoTrue with a one-time random password;
#   3. records only old_id -> new_id + access_token in a mode-0600 session file.
#
# The follow-up restore drill maps schema-declared user FKs from old UUIDs to
# these new Auth UUIDs. The access tokens are then used to prove normal RLS
# access to the recovered household. No email/password/token is printed.

set -euo pipefail

TARGET_PROJECT_REF="${TARGET_PROJECT_REF:-wdwbmvpipbdpomqulsrj}"
APP_ID="family-ops-recovery-v1"
SLOT_ID="household-durable-v1"
SESSION_FILE=""

usage() {
  cat <<'USAGE'
Usage: scripts/prepare_recovery_auth_smoke.sh --session-file <path>

Required env:
  SUPABASE_ACCESS_TOKEN   Management API token used only to read app-save-hub
  API_URL                 Disposable Supabase API URL (normally localhost)
  SERVICE_ROLE_KEY        Disposable Supabase service-role key
  ANON_KEY                Disposable Supabase anon key
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

[ -n "$SESSION_FILE" ] || { echo "ERROR: --session-file is required" >&2; exit 2; }
for v in SUPABASE_ACCESS_TOKEN API_URL SERVICE_ROLE_KEY ANON_KEY; do
  [ -n "${!v:-}" ] || { echo "ERROR: required env var $v is missing" >&2; exit 2; }
done
for cmd in curl jq openssl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command '$cmd' is missing" >&2; exit 2; }
done
case "$API_URL" in
  http://127.0.0.1:*|http://localhost:*|https://127.0.0.1:*|https://localhost:*) ;;
  *)
    if [ "${ALLOW_MANAGED_RECOVERY_TARGET:-0}" != "1" ]; then
      echo "ERROR: refusing non-local Auth smoke target without ALLOW_MANAGED_RECOVERY_TARGET=1" >&2
      exit 3
    fi
    ;;
esac

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

query() {
  local sql="$1"
  local out="$2"
  jq -n --arg query "$sql" '{query:$query}' \
    | curl --fail-with-body --silent --show-error \
        -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d @- \
        "https://api.supabase.com/v1/projects/${TARGET_PROJECT_REF}/database/query" \
        > "$out"
}

SNAPSHOT_RESPONSE="$WORKDIR/snapshot-response.json"
query "select payload from public.app_saves where app_id='${APP_ID}' and slot_id='${SLOT_ID}' order by updated_at desc limit 1;" "$SNAPSHOT_RESPONSE"
jq -e --arg app "$APP_ID" --arg slot "$SLOT_ID" '
  length == 1 and
  .[0].payload.recovery_namespace.app_id == $app and
  .[0].payload.recovery_namespace.slot_id == $slot and
  (.[0].payload.auth_user_refs | type) == "array" and
  (.[0].payload.auth_user_refs | length) >= 1
' "$SNAPSHOT_RESPONSE" >/dev/null || {
  echo "ERROR: no valid Family Ops recovery snapshot is available" >&2
  exit 1
}
jq '.[0].payload.auth_user_refs' "$SNAPSHOT_RESPONSE" > "$WORKDIR/auth-refs.json"

# Duplicate/missing emails would make deterministic safe rebinding impossible.
jq -e '
  all(.[]; (.id | type)=="string" and (.email | type)=="string" and (.email | length)>0) and
  ([.[].id] | unique | length) == length and
  ([.[].email | ascii_downcase] | unique | length) == length
' "$WORKDIR/auth-refs.json" >/dev/null || {
  echo "ERROR: snapshot identity references are not uniquely rebindable" >&2
  exit 1
}

printf '[]\n' > "$SESSION_FILE"
chmod 600 "$SESSION_FILE"

IDENTITY_COUNT="$(jq 'length' "$WORKDIR/auth-refs.json")"
for ((i=0; i<IDENTITY_COUNT; i++)); do
  OLD_ID="$(jq -er ".[$i].id" "$WORKDIR/auth-refs.json")"
  EMAIL="$(jq -er ".[$i].email | ascii_downcase" "$WORKDIR/auth-refs.json")"
  PASSWORD="$(openssl rand -hex 24)"

  CREATE_BODY="$WORKDIR/create-${i}.json"
  jq -n --arg email "$EMAIL" --arg password "$PASSWORD" \
    '{email:$email,password:$password,email_confirm:true}' > "$CREATE_BODY"
  CREATE_RESPONSE="$WORKDIR/create-response-${i}.json"
  curl --fail-with-body --silent --show-error \
    -X POST "${API_URL}/auth/v1/admin/users" \
    -H "apikey: ${SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SERVICE_ROLE_KEY}" \
    -H 'Content-Type: application/json' \
    --data-binary @"$CREATE_BODY" > "$CREATE_RESPONSE"
  NEW_ID="$(jq -er '.id' "$CREATE_RESPONSE")"
  if [ "$NEW_ID" = "$OLD_ID" ]; then
    echo "ERROR: disposable Auth unexpectedly reused a production user UUID" >&2
    exit 1
  fi

  LOGIN_BODY="$WORKDIR/login-${i}.json"
  jq -n --arg email "$EMAIL" --arg password "$PASSWORD" \
    '{email:$email,password:$password}' > "$LOGIN_BODY"
  LOGIN_RESPONSE="$WORKDIR/login-response-${i}.json"
  curl --fail-with-body --silent --show-error \
    -X POST "${API_URL}/auth/v1/token?grant_type=password" \
    -H "apikey: ${ANON_KEY}" \
    -H 'Content-Type: application/json' \
    --data-binary @"$LOGIN_BODY" > "$LOGIN_RESPONSE"
  ACCESS_TOKEN="$(jq -er '.access_token' "$LOGIN_RESPONSE")"
  LOGIN_ID="$(jq -er '.user.id' "$LOGIN_RESPONSE")"
  [ "$LOGIN_ID" = "$NEW_ID" ] || { echo "ERROR: Auth sign-in returned a different user" >&2; exit 1; }

  NEXT="$WORKDIR/sessions-next.json"
  jq --arg old_id "$OLD_ID" --arg new_id "$NEW_ID" --arg token "$ACCESS_TOKEN" \
    '. + [{old_id:$old_id,new_id:$new_id,access_token:$token}]' "$SESSION_FILE" > "$NEXT"
  mv "$NEXT" "$SESSION_FILE"
  chmod 600 "$SESSION_FILE"
  unset PASSWORD ACCESS_TOKEN EMAIL
 done

jq -e --argjson n "$IDENTITY_COUNT" '
  length == $n and
  ([.[].old_id] | unique | length) == $n and
  ([.[].new_id] | unique | length) == $n and
  all(.[]; .old_id != .new_id and (.access_token | length) > 20)
' "$SESSION_FILE" >/dev/null || {
  echo "ERROR: disposable Auth session map is incomplete" >&2
  exit 1
}

echo "Prepared and signed in ${IDENTITY_COUNT} recovered Auth identity/identities in disposable Supabase."
echo "RESULT: PASS — new Auth identities can sign in without restoring production passwords or sessions"
