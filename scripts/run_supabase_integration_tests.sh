#!/usr/bin/env bash
# v6 review fix (P1-6): real-stack integration tests against a genuine
# `supabase start` (Postgres + GoTrue + PostgREST + Kong + edge-runtime),
# run from .github/workflows/ci.yml's `supabase-integration` job.
#
# This intentionally re-tests, at the real environment boundary, invariants
# the plain-Postgres suite (scripts/run_sql_tests.sh) already proves at the
# SQL level against a hand-built auth shim:
#   1. private.webhook_inbox/notification_outbox are unreachable through the
#      real PostgREST Data API (not just "denied by a shim role")
#   2. Edge Function verify_jwt is enforced by the real gateway
#   3. worker-token auth is enforced in-handler before any DB access
#   4. line-webhook-receiver durably persists a real HTTP webhook call
#   5. RLS blocks a real cross-household Data API read
#
# Relies on env vars from `supabase status -o env` (API_URL, ANON_KEY,
# SERVICE_ROLE_KEY, DB_URL) with sane local-default fallbacks in case that
# capture step's output format ever changes.
set -euo pipefail

API_URL="${API_URL:-http://127.0.0.1:54321}"
ANON_KEY="${ANON_KEY:?ANON_KEY not set — did the 'supabase status -o env' step run before this one?}"
SERVICE_ROLE_KEY="${SERVICE_ROLE_KEY:?SERVICE_ROLE_KEY not set}"
DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
LINE_CHANNEL_SECRET="${LINE_CHANNEL_SECRET:?LINE_CHANNEL_SECRET not set}"
CRON_WORKER_TOKEN="${CRON_WORKER_TOKEN:?CRON_WORKER_TOKEN not set}"

fail() { echo "FAIL supabase-integration: $1" >&2; exit 1; }
info() { echo "-- $1"; }

# ---------------------------------------------------------------------------
# 0. wait for the stack to actually answer
# ---------------------------------------------------------------------------
for i in $(seq 1 30); do
  if curl -sS -o /dev/null -w '%{http_code}' "$API_URL/rest/v1/" -H "apikey: $ANON_KEY" 2>/dev/null | grep -qE '^[0-9]+$'; then
    break
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
# 1. private schema unreachable via the real Data API
# ---------------------------------------------------------------------------
info "1. private.webhook_inbox must be unreachable via the Data API (any role)"
for key_name in ANON_KEY SERVICE_ROLE_KEY; do
  key="${!key_name}"
  code=$(curl -sS -o /dev/null -w '%{http_code}' "$API_URL/rest/v1/webhook_inbox?select=*&limit=1" \
    -H "apikey: $key" -H "Authorization: Bearer $key")
  if [ "$code" = "200" ]; then
    fail "private.webhook_inbox was reachable via Data API with $key_name (got 200)"
  fi
  info "   $key_name -> HTTP $code (expected non-200)"
done

info "1b. server_tx_* RPC must be unreachable via the Data API for anon/authenticated"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/server_tx_create_household" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY" -H "Content-Type: application/json" \
  -d '{"p_actor_id":"00000000-0000-0000-0000-000000000000","p_operation_id":"00000000-0000-0000-0000-000000000001","p_household_name":"x","p_display_name":"y"}')
if [ "$code" = "200" ]; then
  fail "server_tx_create_household RPC succeeded via Data API with anon key (got 200)"
fi
info "   anon RPC call -> HTTP $code (expected non-200)"

# ---------------------------------------------------------------------------
# 2. Edge Function verify_jwt is enforced by the real gateway
# ---------------------------------------------------------------------------
info "2. create-household (verify_jwt=true) without Authorization -> 401 before the handler runs"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/create-household" \
  -H "Content-Type: application/json" -d '{}')
[ "$code" = "401" ] || fail "expected 401 for create-household with no JWT, got $code"

# ---------------------------------------------------------------------------
# 2b. Google Sign-In (P1-C): GoTrue's own Google provider is enabled and
# wired to the correct callback — not a live end-to-end login (that needs a
# real Google account/consent, which CI cannot do), but a real smoke test of
# the actual wiring: GoTrue must redirect to Google with exactly the GoTrue
# callback URL (http://127.0.0.1:54321/auth/v1/callback) as redirect_uri,
# proving supabase/config.toml's [auth.external.google].redirect_uri =
# env(GOOGLE_SIGNIN_CALLBACK_URL) is actually taking effect in the running
# stack, not just present in the file.
# ---------------------------------------------------------------------------
info "2b. Google Sign-In onboarding: /auth/v1/authorize?provider=google redirects to Google with the correct callback"
AUTHORIZE_HEADERS=$(curl -sS -o /dev/null -D - "$API_URL/auth/v1/authorize?provider=google&redirect_to=http://localhost:5173" -H "apikey: $ANON_KEY")
AUTHORIZE_STATUS=$(printf '%s' "$AUTHORIZE_HEADERS" | head -1 | grep -oE '[0-9]{3}')
LOCATION=$(printf '%s' "$AUTHORIZE_HEADERS" | grep -i '^location:' | sed 's/^[Ll]ocation: *//' | tr -d '\r')
[[ "$AUTHORIZE_STATUS" =~ ^30[0-9]$ ]] || fail "expected a redirect (3xx) from /auth/v1/authorize?provider=google, got $AUTHORIZE_STATUS"
[[ "$LOCATION" == *"accounts.google.com"* ]] || fail "Google authorize did not redirect to accounts.google.com: $LOCATION"
[[ "$LOCATION" == *"redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Fauth%2Fv1%2Fcallback"* ]] \
  || fail "Google authorize redirect_uri did not match the expected GoTrue callback http://127.0.0.1:54321/auth/v1/callback: $LOCATION"
info "   OK: redirects to Google with redirect_uri=http://127.0.0.1:54321/auth/v1/callback"

# ---------------------------------------------------------------------------
# 3. worker-token auth enforced in-handler, before any DB access
# ---------------------------------------------------------------------------
info "3a. send-notifications (worker) with no token -> 401"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/send-notifications" \
  -H "apikey: $ANON_KEY")
[ "$code" = "401" ] || fail "expected 401 for send-notifications with no worker token, got $code"

info "3b. send-notifications with wrong token -> 401"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/send-notifications" \
  -H "apikey: $ANON_KEY" -H "X-Family-Ops-Worker-Token: wrong-token")
[ "$code" = "401" ] || fail "expected 401 for send-notifications with wrong worker token, got $code"

info "3c. send-notifications with the correct token -> 200"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/send-notifications" \
  -H "apikey: $ANON_KEY" -H "X-Family-Ops-Worker-Token: $CRON_WORKER_TOKEN")
[ "$code" = "200" ] || fail "expected 200 for send-notifications with the correct worker token, got $code"

# ---------------------------------------------------------------------------
# 4. line-webhook-receiver: real HTTP call durably persists a webhook_inbox row
# ---------------------------------------------------------------------------
info "4. line-webhook-receiver durable insert (end to end over real HTTP)"
EVENT_ID="ci-integration-$(date +%s)-$$"
BODY=$(cat <<JSON
{"events":[{"type":"message","webhookEventId":"$EVENT_ID","source":{"userId":"Utestuser123"}}]}
JSON
)
SIGNATURE=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$LINE_CHANNEL_SECRET" -binary | base64)

code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/line-webhook-receiver" \
  -H "Content-Type: application/json" -H "X-Line-Signature: $SIGNATURE" -d "$BODY")
[ "$code" = "200" ] || fail "expected 200 from a validly-signed line-webhook-receiver call, got $code"

ROW_COUNT=$(psql "$DB_URL" -t -A -c "select count(*) from private.webhook_inbox where provider_event_id = '$EVENT_ID';")
[ "$ROW_COUNT" = "1" ] || fail "expected exactly 1 durable webhook_inbox row for $EVENT_ID, got $ROW_COUNT"

info "4b. invalid signature -> 401, never persisted"
BAD_EVENT_ID="ci-integration-bad-$(date +%s)-$$"
BAD_BODY=$(cat <<JSON
{"events":[{"type":"message","webhookEventId":"$BAD_EVENT_ID","source":{"userId":"Utestuser123"}}]}
JSON
)
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/line-webhook-receiver" \
  -H "Content-Type: application/json" -H "X-Line-Signature: not-a-real-signature" -d "$BAD_BODY")
[ "$code" = "401" ] || fail "expected 401 for an invalid LINE signature, got $code"
BAD_ROW_COUNT=$(psql "$DB_URL" -t -A -c "select count(*) from private.webhook_inbox where provider_event_id = '$BAD_EVENT_ID';")
[ "$BAD_ROW_COUNT" = "0" ] || fail "an invalidly-signed webhook must never be persisted, found $BAD_ROW_COUNT row(s)"

# ---------------------------------------------------------------------------
# 5. RLS blocks a real cross-household Data API read
# ---------------------------------------------------------------------------
info "5. RLS cross-household isolation over the real Data API"

create_and_login_user() {
  local email="$1" password="$2"
  curl -sS -X POST "$API_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$password\",\"email_confirm\":true}" >/dev/null

  curl -sS -X POST "$API_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$password\"}" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

STAMP=$(date +%s)
JWT_A=$(create_and_login_user "fo-ci-a-$STAMP@example.com" "correct-horse-battery-staple-A")
JWT_B=$(create_and_login_user "fo-ci-b-$STAMP@example.com" "correct-horse-battery-staple-B")

OP_A=$(python3 -c "import uuid; print(uuid.uuid4())")
OP_B=$(python3 -c "import uuid; print(uuid.uuid4())")

HH_A=$(curl -sS -X POST "$API_URL/functions/v1/create-household" \
  -H "Authorization: Bearer $JWT_A" -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"operation_id\":\"$OP_A\",\"household_name\":\"CI Household A\",\"display_name\":\"A\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['household_id'])")

HH_B=$(curl -sS -X POST "$API_URL/functions/v1/create-household" \
  -H "Authorization: Bearer $JWT_B" -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"operation_id\":\"$OP_B\",\"household_name\":\"CI Household B\",\"display_name\":\"B\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['household_id'])")

[ -n "$HH_A" ] && [ "$HH_A" != "None" ] || fail "create-household for user A did not return a household_id"
[ -n "$HH_B" ] && [ "$HH_B" != "None" ] || fail "create-household for user B did not return a household_id"
[ "$HH_A" != "$HH_B" ] || fail "user A and user B unexpectedly ended up in the same household"

VISIBLE_TO_A=$(curl -sS "$API_URL/rest/v1/households?select=id" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" \
  | python3 -c "import sys,json; print(','.join(r['id'] for r in json.load(sys.stdin)))")
if [[ ",$VISIBLE_TO_A," == *",$HH_B,"* ]]; then
  fail "user A could see household B via the real Data API (RLS cross-household leak)"
fi
if [[ ",$VISIBLE_TO_A," != *",$HH_A,"* ]]; then
  fail "user A could not see their own household via the real Data API"
fi

info "OK: household A only sees its own household, never B's, over the real PostgREST Data API"

# ---------------------------------------------------------------------------
# 6. an authenticated user's real JWT (not anon, not service_role) must
# still be denied direct server_tx_* RPC access via the Data API — section
# 1b above only proved this for the anon key; this proves the same REVOKE
# holds for a genuine logged-in user's `authenticated`-role JWT, which is
# the actual role server_tx_* grants are written against.
# ---------------------------------------------------------------------------
info "6. authenticated user's real JWT must not be able to call server_tx_* RPCs via the Data API"
OP_AUTH_DENY=$(python3 -c "import uuid; print(uuid.uuid4())")
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/server_tx_create_household" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" -H "Content-Type: application/json" \
  -d "{\"p_actor_id\":\"00000000-0000-0000-0000-000000000000\",\"p_operation_id\":\"$OP_AUTH_DENY\",\"p_household_name\":\"x\",\"p_display_name\":\"y\"}")
if [ "$code" = "200" ]; then
  fail "server_tx_create_household RPC succeeded via Data API with an authenticated user's real JWT (got 200) — EXECUTE must be revoked from authenticated"
fi
info "   authenticated JWT RPC call -> HTTP $code (expected non-200)"

# ---------------------------------------------------------------------------
# 7. WP2 end-to-end: create-task -> visible via real Data API read (RLS) ->
# complete-task -> status reflected, over the real HTTP stack (not the
# plain-Postgres auth shim). Also proves verify_jwt=true gates a WP2
# function the same way section 2 proved it for create-household.
# ---------------------------------------------------------------------------
info "7. WP2 create-task / complete-task end to end over the real Data API + Edge Functions"

code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/create-task" \
  -H "Content-Type: application/json" -d '{}')
[ "$code" = "401" ] || fail "expected 401 for create-task with no JWT, got $code"

OP_CREATE_TASK=$(python3 -c "import uuid; print(uuid.uuid4())")
TASK_ID=$(curl -sS -X POST "$API_URL/functions/v1/create-task" \
  -H "Authorization: Bearer $JWT_A" -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"operation_id\":\"$OP_CREATE_TASK\",\"title\":\"CI integration task\",\"category\":\"chore\",\"scheduled_date\":\"$(date +%Y-%m-%d)\",\"completion_mode\":\"whole\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['task_id'])")
[ -n "$TASK_ID" ] && [ "$TASK_ID" != "None" ] || fail "create-task did not return a task_id"

VISIBLE_TASK=$(curl -sS "$API_URL/rest/v1/task_instances?select=id,status&id=eq.$TASK_ID" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" \
  | python3 -c "import sys,json; rows=json.load(sys.stdin); print(rows[0]['status'] if rows else 'MISSING')")
[ "$VISIBLE_TASK" = "todo" ] || fail "expected the newly created task to be readable via the real Data API with status=todo, got '$VISIBLE_TASK'"

OP_COMPLETE_TASK=$(python3 -c "import uuid; print(uuid.uuid4())")
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/complete-task" \
  -H "Authorization: Bearer $JWT_A" -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"operation_id\":\"$OP_COMPLETE_TASK\",\"task_id\":\"$TASK_ID\",\"completion_actor\":\"self\"}")
[ "$code" = "200" ] || fail "expected 200 from complete-task, got $code"

COMPLETED_STATUS=$(curl -sS "$API_URL/rest/v1/task_instances?select=status&id=eq.$TASK_ID" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['status'])")
[ "$COMPLETED_STATUS" = "completed" ] || fail "expected task status=completed via the real Data API after complete-task, got '$COMPLETED_STATUS'"

# user B (different household) must not be able to read user A's task
CROSS_HOUSEHOLD_READ=$(curl -sS "$API_URL/rest/v1/task_instances?select=id&id=eq.$TASK_ID" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_B" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
[ "$CROSS_HOUSEHOLD_READ" = "0" ] || fail "user B must not be able to read user A's task_instances row via RLS, got $CROSS_HOUSEHOLD_READ row(s)"

info "OK: create-task -> Data API read -> complete-task -> Data API read round-trips correctly, and stays RLS-isolated from household B"

echo "== all supabase-integration tests passed =="
