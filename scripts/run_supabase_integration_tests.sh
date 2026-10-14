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

# Saved progress must survive reopening through the same embedded query as Today/planning.
info "7a. progress save -> latest embedded note read, open task state and household isolation"
PROGRESS_CREATE_OP=$(python3 -c 'import uuid; print(uuid.uuid4())')
PROGRESS_TASK_ID=$(curl -fsS -X POST "$API_URL/functions/v1/create-task" \
  -H "Authorization: Bearer $JWT_A" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
  -d "{\"operation_id\":\"$PROGRESS_CREATE_OP\",\"title\":\"Progress visibility\",\"scheduled_date\":\"$(date +%Y-%m-%d)\",\"completion_mode\":\"whole\"}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["task_id"])')
for progress_revision in 1 2; do
  progress_operation=$(python3 -c 'import uuid; print(uuid.uuid4())')
  curl -fsS -X POST "$API_URL/functions/v1/edit-task" \
    -H "Authorization: Bearer $JWT_A" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
    -d "{\"action\":\"record_progress\",\"operation_id\":\"$progress_operation\",\"task_id\":\"$PROGRESS_TASK_ID\",\"expected_revision\":$progress_revision,\"observed_note\":\"saved-$progress_revision\",\"work_done_note\":\"started washing\",\"remaining_note\":\"unloading remains\",\"share_with_household\":false,\"ack_policy\":\"none\"}" \
    | python3 -c 'import json,sys; assert json.load(sys.stdin)["revision"] >= 2'
done
for progress_reader in A B; do
  progress_jwt_name="JWT_$progress_reader"
  progress_rows=$(curl -fsS --get "$API_URL/rest/v1/task_instances" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer ${!progress_jwt_name}" \
    --data-urlencode 'select=id,status,latest_work_progress:task_events!task_events_household_id_task_instance_id_fkey(id,payload)' \
    --data-urlencode "household_id=eq.$HH_A" --data-urlencode "id=in.($PROGRESS_TASK_ID,$TASK_ID)" \
    --data-urlencode 'latest_work_progress.event_type=eq.work_progress_recorded' \
    --data-urlencode 'latest_work_progress.order=created_at.desc,id.desc' \
    --data-urlencode 'latest_work_progress.limit=1')
  python3 -c 'import json,sys; rows=json.load(sys.stdin)
if sys.argv[1]=="B":
 assert rows==[], "progress notes leaked across households"
else:
 assert len(rows)==2, "embedding removed a task without progress"
 task=next(row for row in rows if row["id"]==sys.argv[2])
 assert task["status"]=="todo", "note save changed the completion state"
 assert len(task["latest_work_progress"])==1, "per-task note limit failed"
 assert task["latest_work_progress"][0]["payload"]["observed_note"]=="saved-2", "latest saved note was not restored"
 assert next(row for row in rows if row["id"]!=sys.argv[2])["latest_work_progress"]==[], "unrelated audit events became progress notes"
' "$progress_reader" "$PROGRESS_TASK_ID" <<< "$progress_rows"
done
info "OK: progress body survives save/read, latest note embedding preserves empty tasks, completion state and household RLS"

# 7b. Both input shapes must resolve to the shared outcome implementation via PostgREST.
info "7b. could-not-do and undo with current and legacy Edge input shapes"
OP_OUTCOME_CREATE=$(python3 -c 'import uuid; print(uuid.uuid4())')
OUTCOME_TASK_ID=$(curl -fsS -X POST "$API_URL/functions/v1/create-task" \
  -H "Authorization: Bearer $JWT_A" -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"operation_id\":\"$OP_OUTCOME_CREATE\",\"title\":\"Outcome compatibility\",\"category\":\"chore\",\"scheduled_date\":\"$(date +%Y-%m-%d)\",\"completion_mode\":\"whole\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['task_id'])")
for outcome_step in 'could_not_do:current:skipped' 'could_not_do_undo:current:todo' 'could_not_do:legacy:skipped' 'could_not_do_undo:legacy:todo'; do
  IFS=: read -r outcome_action outcome_client outcome_status <<< "$outcome_step"
  outcome_revision_field=''
  if [ "$outcome_client" = 'current' ]; then
    outcome_revision=$(curl -fsS "$API_URL/rest/v1/task_instances?select=revision&id=eq.$OUTCOME_TASK_ID" \
      -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["revision"])')
    outcome_revision_field=",\"expected_revision\":$outcome_revision"
  fi
  outcome_operation=$(python3 -c 'import uuid; print(uuid.uuid4())')
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/complete-task" \
    -H "Authorization: Bearer $JWT_A" -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"operation_id\":\"$outcome_operation\",\"task_id\":\"$OUTCOME_TASK_ID\",\"action\":\"$outcome_action\"$outcome_revision_field}")
  [ "$code" = '200' ] || fail "$outcome_client $outcome_action failed via Edge/PostgREST: $code"
  outcome_actual=$(curl -fsS "$API_URL/rest/v1/task_instances?select=status&id=eq.$OUTCOME_TASK_ID" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["status"])')
  [ "$outcome_actual" = "$outcome_status" ] || fail "$outcome_client $outcome_action returned status=$outcome_actual"
done
info "OK: current and legacy recorded-outcome calls share the real Edge/PostgREST implementation"

# 7c. Shared setup endpoint keeps the old onboarding input and scopes new actions to the caller.
info "7c. shared family setup endpoint: legacy onboarding, new actions, and household isolation"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/complete-onboarding-step" \
  -H 'Content-Type: application/json' -d '{"action":"read"}')
[ "$code" = '401' ] || fail "family setup without JWT returned $code"
# Deferring setup establishes the earlier steps required by the legacy ordered flow.
for setup_input in '{"action":"finish_later"}' '{"step":"connections"}'; do
  setup_operation=$(python3 -c 'import uuid; print(uuid.uuid4())')
  setup_payload=$(jq -c --arg operation_id "$setup_operation" '. + {operation_id:$operation_id}' <<< "$setup_input")
  setup_household=$(curl -fsS -X POST "$API_URL/functions/v1/complete-onboarding-step" \
    -H "Authorization: Bearer $JWT_A" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
    -d "$setup_payload" | python3 -c 'import json,sys; print(json.load(sys.stdin)["household_id"])')
  [ "$setup_household" = "$HH_A" ] || fail "shared setup returned the wrong household"
done
setup_operation=$(python3 -c 'import uuid; print(uuid.uuid4())')
curl -fsS -X POST "$API_URL/functions/v1/complete-onboarding-step" \
  -H "Authorization: Bearer $JWT_A" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
  -d "{\"operation_id\":\"$setup_operation\",\"action\":\"save_context\",\"payload\":{\"display_name\":\"CI child\",\"school_display_name\":\"CI nursery\",\"effective_from\":\"2026-10-01\"}}" \
  | python3 -c 'import json,sys; result=json.load(sys.stdin); assert result["child_id"] and result["context_id"]'
for setup_actor in A B; do
  setup_jwt_name="JWT_$setup_actor"
  setup_child_count=$(curl -fsS -X POST "$API_URL/functions/v1/complete-onboarding-step" \
    -H "Authorization: Bearer ${!setup_jwt_name}" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
    -d '{"action":"read"}' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["children"]))')
  if [ "$setup_actor" = A ]; then
    [ "$setup_child_count" = 1 ] || fail "family setup did not return the caller's child"
  else
    [ "$setup_child_count" = 0 ] || fail "family setup leaked another household's child"
  fi
done
info "OK: shared family setup keeps legacy inputs and household isolation over real Edge/PostgREST"

# Old LINE previews are also visible in PWA. Their confirmation must use the
# same intent boundary, while ordinary confirmations retain successful replay.
info "7d. PWA confirmation rejects a generic transport draft and preserves ordinary replay"
PENDING_ACTOR_ID=$(curl -fsS "$API_URL/auth/v1/user" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
for pending_kind in transport ordinary; do
  pending_operation=$(python3 -c 'import uuid; print(uuid.uuid4())')
  pending_title='CI ordinary task'
  pending_raw='明日、普通の用事を追加して'
  if [ "$pending_kind" = transport ]; then
    pending_title='明日の送り担当をパパに変更'
    pending_raw='明日の送りは私に変更してください'
  fi
  pending_create=$(jq -nc --arg actor "$PENDING_ACTOR_ID" --arg household "$HH_A" --arg op "$pending_operation" \
    --arg title "$pending_title" --arg raw "$pending_raw" --arg day "$(date +%Y-%m-%d)" \
    '{p_actor_id:$actor,p_household_id:$household,p_operation_id:$op,p_source:"line",p_action_type:"task_create_once",p_normalized_payload:{title:$title,raw_text:$raw,scheduled_date:$day,planned_assignee_user_id:$actor},p_ttl_minutes:30}')
  pending_id=$(curl -fsS -X POST "$API_URL/rest/v1/rpc/server_tx_create_pending_action" \
    -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H 'Content-Type: application/json' \
    -d "$pending_create" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pending_action_id"])')
  pending_confirm=$(jq -nc --arg id "$pending_id" '{pending_action_id:$id}')
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/confirm-pending-action" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" -H 'Content-Type: application/json' -d "$pending_confirm")
  if [ "$pending_kind" = transport ]; then
    [ "$code" = 400 ] || fail "generic transport draft must not confirm: $code"
    pending_state=$(curl -fsS -X POST "$API_URL/rest/v1/rpc/server_tx_get_pending_action" \
      -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H 'Content-Type: application/json' \
      -d "{\"p_actor_id\":\"$PENDING_ACTOR_ID\",\"p_pending_action_id\":\"$pending_id\"}" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
    [ "$pending_state" = draft ] || fail "rejected transport preview changed state"
  else
    [ "$code" = 200 ] || fail "ordinary draft confirmation failed: $code"
    code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/confirm-pending-action" \
      -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" -H 'Content-Type: application/json' -d "$pending_confirm")
    [ "$code" = 200 ] || fail "ordinary confirmed replay failed: $code"
  fi
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/confirm-pending-action" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_B" -H 'Content-Type: application/json' -d "$pending_confirm")
  [ "$code" != 200 ] || fail "different household confirmed another actor's draft"
done
info "OK: real PWA confirmation keeps transport drafts open, ordinary replay idempotent, and household boundaries intact"

# Native LINE previews use real PostgREST RPC calls and the canonical task row.
# The fixture stays in this disposable CI stack; no LINE provider is called.
info "7e. native LINE transport preview -> explicit confirm -> actual assignment and replay"
TRANSPORT_TASK_ID=$(psql "$DB_URL" -v ON_ERROR_STOP=1 -Atq \
  -v actor_id="$PENDING_ACTOR_ID" -v household_id="$HH_A" <<'SQL'
insert into public.task_instances(
  household_id,task_definition_id,origin,title,category,task_kind,routine_phase,
  scheduled_date,due_at,completion_mode,status,source,created_by,assignment_mode
)
select :'household_id'::uuid,id,'manual','CI LINE transport','dropoff','transport','morning',
  (now() at time zone 'Asia/Tokyo')::date+1,
  (((now() at time zone 'Asia/Tokyo')::date+1)::text||' 08:10')::timestamp at time zone 'Asia/Tokyo',
  'whole','todo','test',:'actor_id'::uuid,'anyone'
from public.task_definitions where household_id=:'household_id'::uuid and code='dropoff'
returning id;
SQL
)
[[ "$TRANSPORT_TASK_ID" =~ ^[0-9a-f-]{36}$ ]] || fail "native transport fixture missing"
TRANSPORT_OPERATION=$(python3 -c 'import uuid; print(uuid.uuid4())')
TRANSPORT_PREPARE=$(jq -nc --arg actor "$PENDING_ACTOR_ID" --arg op "$TRANSPORT_OPERATION" --arg task "$TRANSPORT_TASK_ID" \
  '{p_actor_id:$actor,p_operation_id:$op,p_task_id:$task,p_assignee_user_id:$actor,p_expected_revision:1}')
TRANSPORT_READ=$(jq -nc --arg actor "$PENDING_ACTOR_ID" '{p_actor_id:$actor}')
TRANSPORT_SNAPSHOT=$(curl -fsS -X POST "$API_URL/rest/v1/rpc/server_tx_prepare_line_transport_assignment_v1" \
  -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H 'Content-Type: application/json' \
  -d "$TRANSPORT_PREPARE" | jq -ce --arg task "$TRANSPORT_TASK_ID" --arg actor "$PENDING_ACTOR_ID" \
  'select(.status=="draft" and .task_id==$task and .actor_id==$actor and .assignee_user_id==$actor and .expected_revision==1 and .code=="dropoff")')
TRANSPORT_PREVIEW_ID=$(jq -er '.id' <<<"$TRANSPORT_SNAPSHOT")
TRANSPORT_DECIDE=$(jq -nc --arg actor "$PENDING_ACTOR_ID" --arg id "$TRANSPORT_PREVIEW_ID" \
  '{p_actor_id:$actor,p_preview_id:$id,p_action:"confirm_agreed"}')

# Valid bodies ensure denial comes from grants, rather than malformed arguments.
for transport_rpc in server_tx_prepare_line_transport_assignment_v1 server_read_line_transport_assignment_preview_v1 server_tx_decide_line_transport_assignment_v1; do
  case "$transport_rpc" in
    server_tx_prepare*) transport_body="$TRANSPORT_PREPARE" ;;
    server_read*) transport_body="$TRANSPORT_READ" ;;
    server_tx_decide*) transport_body="$TRANSPORT_DECIDE" ;;
  esac
  for transport_token_name in ANON_KEY JWT_A; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/$transport_rpc" \
      -H "apikey: $ANON_KEY" -H "Authorization: Bearer ${!transport_token_name}" -H 'Content-Type: application/json' -d "$transport_body")
    case "$code" in 401|403|404) ;; *) fail "$transport_rpc exposed to $transport_token_name: $code" ;; esac
  done
done
TRANSPORT_READ_BACK=$(curl -fsS -X POST "$API_URL/rest/v1/rpc/server_read_line_transport_assignment_preview_v1" \
  -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H 'Content-Type: application/json' -d "$TRANSPORT_READ")
[ "$(jq -cS . <<<"$TRANSPORT_READ_BACK")" = "$(jq -cS . <<<"$TRANSPORT_SNAPSHOT")" ] || fail "native preview read changed snapshot"
TRANSPORT_BEFORE=$(curl -fsS "$API_URL/rest/v1/task_instances?id=eq.$TRANSPORT_TASK_ID&select=revision,assignment_mode,planned_assignee_id" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A")
jq -e 'length==1 and .[0].revision==1 and .[0].assignment_mode=="anyone" and .[0].planned_assignee_id==null' \
  <<<"$TRANSPORT_BEFORE" >/dev/null || fail "native preview changed task before explicit confirm"
TRANSPORT_OTHER_ACTOR=$(curl -fsS "$API_URL/auth/v1/user" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_B" | jq -er '.id')
TRANSPORT_OTHER_READ=$(jq -nc --arg actor "$TRANSPORT_OTHER_ACTOR" '{p_actor_id:$actor}')
TRANSPORT_OTHER_SNAPSHOT=$(curl -fsS -X POST "$API_URL/rest/v1/rpc/server_read_line_transport_assignment_preview_v1" \
  -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H 'Content-Type: application/json' -d "$TRANSPORT_OTHER_READ")
[ "$TRANSPORT_OTHER_SNAPSHOT" = null ] || fail "another actor read native preview"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/server_tx_decide_line_transport_assignment_v1" \
  -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H 'Content-Type: application/json' \
  -d "$(jq --arg actor "$TRANSPORT_OTHER_ACTOR" '.p_actor_id=$actor' <<<"$TRANSPORT_DECIDE")")
[ "$code" = 400 ] || fail "another actor's native confirm was not rejected: $code"
for transport_attempt in 1 2; do
  TRANSPORT_RESULT=$(curl -fsS -X POST "$API_URL/rest/v1/rpc/server_tx_decide_line_transport_assignment_v1" \
    -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H 'Content-Type: application/json' -d "$TRANSPORT_DECIDE")
  jq -e --arg task "$TRANSPORT_TASK_ID" '.status=="succeeded" and .result.task_id==$task and .result.revision==2' \
    <<<"$TRANSPORT_RESULT" >/dev/null || fail "native confirm/replay failed on attempt $transport_attempt"
  if [ "$transport_attempt" = 1 ]; then
    TRANSPORT_FIRST_RESULT=$(jq -cS . <<<"$TRANSPORT_RESULT")
  else
    [ "$(jq -cS . <<<"$TRANSPORT_RESULT")" = "$TRANSPORT_FIRST_RESULT" ] || fail "native replay changed saved result"
  fi
done
TRANSPORT_AFTER=$(curl -fsS "$API_URL/rest/v1/task_instances?id=eq.$TRANSPORT_TASK_ID&select=revision,assignment_mode,planned_assignee_id,assignment_source" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A")
jq -e --arg actor "$PENDING_ACTOR_ID" 'length==1 and .[0].revision==2 and .[0].assignment_mode=="person" and .[0].planned_assignee_id==$actor and .[0].assignment_source=="agreement"' \
  <<<"$TRANSPORT_AFTER" >/dev/null || fail "native confirm did not update actual transport task"
TRANSPORT_EVENTS=$(curl -fsS "$API_URL/rest/v1/task_events?task_instance_id=eq.$TRANSPORT_TASK_ID&select=event_type,source,actor_id" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A")
jq -e --arg actor "$PENDING_ACTOR_ID" 'length==1 and .[0].event_type=="assignment_agreed" and .[0].source=="line" and .[0].actor_id==$actor' \
  <<<"$TRANSPORT_EVENTS" >/dev/null || fail "native confirm/replay event missing, duplicated, or wrong source"
info "OK: native preview stays inert until explicit confirmation; actual assignment changes once and RPCs remain service-only"

# 8. Rich schedule save, real private file upload/download and household isolation.
info "8. scheduler metadata and private attachments over real Storage + Data API"
OP_SCHEDULE=$(python3 -c 'import uuid; print(uuid.uuid4())')
SCHEDULE_DATE=$(date +%Y-%m-%d)
SCHEDULE_ID=$(curl -fsS -X POST "$API_URL/functions/v1/create-task" \
  -H "Authorization: Bearer $JWT_A" -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"operation_id\":\"$OP_SCHEDULE\",\"title\":\"Schedule with attachment\",\"scheduled_date\":\"$SCHEDULE_DATE\",\"calendar_visibility\":\"special\",\"completion_mode\":\"whole\",\"scheduler_details\":{\"ends_on\":\"$SCHEDULE_DATE\",\"notes\":\"Long nursery notice\",\"checklist\":[\"Bottle\",\"Hat\"]}}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["task_id"])')
[ -n "$SCHEDULE_ID" ] || fail "scheduler create returned no task id"
JOINED=$(curl -fsS "$API_URL/rest/v1/task_instances?select=id,task_schedule_details(details)&id=eq.$SCHEDULE_ID" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)[0]["task_schedule_details"]; r=r[0] if isinstance(r,list) else r; print(r["details"]["notes"])')
[ "$JOINED" = "Long nursery notice" ] || fail "scheduler metadata relation did not round-trip"
OP_ATTACHMENT=$(python3 -c 'import uuid; print(uuid.uuid4())')
OBJECT_PATH="$HH_A/$SCHEDULE_ID/$OP_ATTACHMENT"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/storage/v1/object/schedule-attachments/$OBJECT_PATH" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" -H "Content-Type: text/plain" --data-binary 'Nursery notice')
[ "$code" = "200" ] || fail "same-household attachment upload failed: $code"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/edit-task" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" -H "Content-Type: application/json" \
  -d "{\"operation_id\":\"$OP_ATTACHMENT\",\"sharing_action\":\"register_attachment\",\"task_id\":\"$SCHEDULE_ID\",\"file_name\":\"notice.txt\",\"object_path\":\"$OBJECT_PATH\",\"mime_type\":\"text/plain\",\"size_bytes\":14}")
[ "$code" = "200" ] || fail "attachment metadata write failed: $code"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/storage/v1/object/schedule-attachments/$HH_A/$SCHEDULE_ID/other.txt" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_B" -H "Content-Type: text/plain" --data-binary 'Blocked')
[ "$code" != "200" ] || fail "different household uploaded an attachment"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/storage/v1/object/sign/schedule-attachments/$OBJECT_PATH" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_B" -H "Content-Type: application/json" -d '{"expiresIn":300}')
[ "$code" != "200" ] || fail "different household obtained an attachment download URL"
SIGNED_PATH=$(curl -fsS -X POST "$API_URL/storage/v1/object/sign/schedule-attachments/$OBJECT_PATH" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" -H "Content-Type: application/json" -d '{"expiresIn":300}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["signedURL"])')
CONTENT=$(curl -fsS "$API_URL/storage/v1$SIGNED_PATH")
[ "$CONTENT" = "Nursery notice" ] || fail "private attachment download did not round-trip"
code=$(curl -sS -o /dev/null -w '%{http_code}' "$API_URL/storage/v1/object/public/schedule-attachments/$OBJECT_PATH")
[ "$code" != "200" ] || fail "private attachment was accessible as a public file"
OP_COMMENT=$(python3 -c 'import uuid; print(uuid.uuid4())')
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/edit-task" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" -H "Content-Type: application/json" \
  -d "{\"operation_id\":\"$OP_COMMENT\",\"sharing_action\":\"add_comment\",\"task_id\":\"$SCHEDULE_ID\",\"body\":\"Bring the bottle\"}")
[ "$code" = "200" ] || fail "schedule comment write failed: $code"
CROSS_COMMENTS=$(curl -fsS "$API_URL/rest/v1/schedule_comments?task_id=eq.$SCHEDULE_ID" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_B" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')
[ "$CROSS_COMMENTS" = "0" ] || fail "different household read schedule comments"
OP_FOREIGN_COMMENT=$(python3 -c 'import uuid; print(uuid.uuid4())')
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/edit-task" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_B" -H "Content-Type: application/json" \
  -d "{\"operation_id\":\"$OP_FOREIGN_COMMENT\",\"sharing_action\":\"add_comment\",\"task_id\":\"$SCHEDULE_ID\",\"body\":\"Blocked\"}")
[ "$code" = "403" ] || fail "different household comment mutation was not rejected: $code"
ATTACHMENT_ID=$(curl -fsS "$API_URL/rest/v1/schedule_attachments?task_id=eq.$SCHEDULE_ID&select=id" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])')
OP_DELETE=$(python3 -c 'import uuid; print(uuid.uuid4())')
for attempt in 1 2; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/edit-task" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT_A" -H "Content-Type: application/json" \
    -d "{\"operation_id\":\"$OP_DELETE\",\"sharing_action\":\"delete_attachment\",\"task_id\":\"$SCHEDULE_ID\",\"attachment_id\":\"$ATTACHMENT_ID\"}")
  [ "$code" = "200" ] || fail "attachment removal/replay failed: $code"
done
code=$(curl -sS -o /dev/null -w '%{http_code}' "$API_URL/storage/v1$SIGNED_PATH")
[ "$code" != "200" ] || fail "removed attachment bytes remained accessible"
info "OK: schedule details, private attachment bytes, and comments round-trip and stay household-isolated"

echo "== all supabase-integration tests passed =="
