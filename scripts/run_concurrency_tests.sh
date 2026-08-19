#!/usr/bin/env bash
# True-parallel concurrency tests that a single sequential psql script cannot
# exercise: two real backends racing on the same lock. Run after
# run_sql_tests.sh against the same scratch database.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5544}"
export PGUSER="${PGUSER:-postgres}"
TEST_DB="${1:-family_ops_sql_test}"

psql_svc() {
  psql -v ON_ERROR_STOP=1 -d "$TEST_DB" -q -t -A -c "set role service_role; $1"
}

uuidgen() {
  psql -v ON_ERROR_STOP=1 -d "$TEST_DB" -q -t -A -c "select gen_random_uuid();"
}

fail() { echo "FAIL concurrency: $1" >&2; exit 1; }

echo "== concurrency: join-household race for the last adult seat (MI-HH03) =="

OWNER=$(uuidgen); JOINER_A=$(uuidgen); JOINER_B=$(uuidgen)
psql_svc "insert into auth.users (id) values ('$OWNER'), ('$JOINER_A'), ('$JOINER_B');" >/dev/null

HH_ID=$(psql_svc "select (public.server_tx_create_household('$OWNER', gen_random_uuid(), 'Race HH', 'Owner')->>'household_id');")

TOKEN_A=$(psql_svc "select (public.server_tx_create_household_invite('$OWNER', gen_random_uuid())->>'raw_token');")
TOKEN_B=$(psql_svc "select (public.server_tx_create_household_invite('$OWNER', gen_random_uuid())->>'raw_token');")

# Both joins start inside an explicit transaction that sleeps briefly right
# after taking the household_members row lock (via a deliberately-slowed
# duplicate of the same lock statement) so the two backends are guaranteed to
# overlap instead of racing to complete before the other even starts.
run_join() {
  local actor="$1" token="$2" outfile="$3"
  psql -v ON_ERROR_STOP=1 -d "$TEST_DB" -q -t -A <<SQL > "$outfile" 2>&1 &
set role service_role;
select pg_sleep(random() * 0.3);
select public.server_tx_join_household('$actor', gen_random_uuid(), '$token', 'Racer')::text;
SQL
}

OUT_A=$(mktemp); OUT_B=$(mktemp)
run_join "$JOINER_A" "$TOKEN_A" "$OUT_A"
run_join "$JOINER_B" "$TOKEN_B" "$OUT_B"
wait

SUCCESS_COUNT=0
grep -q "household_id" "$OUT_A" && SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
grep -q "household_id" "$OUT_B" && SUCCESS_COUNT=$((SUCCESS_COUNT + 1))

if [ "$SUCCESS_COUNT" -ne 1 ]; then
  echo "--- joiner A output ---"; cat "$OUT_A"
  echo "--- joiner B output ---"; cat "$OUT_B"
  fail "expected exactly one of two concurrent joins for the last seat to succeed, got $SUCCESS_COUNT"
fi

ADULT_COUNT=$(psql_svc "select count(*) from public.household_members where household_id = '$HH_ID' and member_role = 'adult';")
[ "$ADULT_COUNT" -eq 2 ] || fail "expected exactly 2 adults after the race, got $ADULT_COUNT"

if ! grep -q "HOUSEHOLD_FULL" "$OUT_A" "$OUT_B"; then
  fail "expected the losing joiner to see HOUSEHOLD_FULL"
fi

echo "OK: exactly one concurrent joiner won the last adult seat, the other got HOUSEHOLD_FULL"

echo "== concurrency: create-household double-tap same operation_id (M-01 style) =="

ACTOR=$(uuidgen)
psql_svc "insert into auth.users (id) values ('$ACTOR');" >/dev/null
OP_ID=$(psql -v ON_ERROR_STOP=1 -d "$TEST_DB" -q -t -A -c "select gen_random_uuid();")

run_create() {
  local outfile="$1"
  psql -v ON_ERROR_STOP=1 -d "$TEST_DB" -q -t -A <<SQL > "$outfile" 2>&1 &
set role service_role;
select pg_sleep(random() * 0.2);
select public.server_tx_create_household('$ACTOR', '$OP_ID', 'Double Tap HH', 'Actor')::text;
SQL
}

OUT_C=$(mktemp); OUT_D=$(mktemp)
run_create "$OUT_C"
run_create "$OUT_D"
wait

HH_COUNT=$(psql_svc "select count(*) from public.households where name = 'Double Tap HH';")
[ "$HH_COUNT" -eq 1 ] || fail "double-tap create-household with the same operation_id must create exactly one household, got $HH_COUNT"

ID_C=$(grep -o '"household_id": "[a-f0-9-]*"' "$OUT_C" | head -1 || true)
ID_D=$(grep -o '"household_id": "[a-f0-9-]*"' "$OUT_D" | head -1 || true)
[ -n "$ID_C" ] || fail "first double-tap call did not return a household_id ($(cat "$OUT_C"))"
[ "$ID_C" = "$ID_D" ] || fail "both double-tap calls must return the same household_id"

echo "OK: concurrent double-tap create-household produced exactly one household and both calls replayed the same id"

echo "== concurrency: LINE quota atomic reservation races (LQA01/LQA02) =="

QUOTA_OWNER=$(uuidgen)
psql_svc "insert into auth.users (id) values ('$QUOTA_OWNER');" >/dev/null
QHH=$(psql_svc "select (public.server_tx_create_household('$QUOTA_OWNER', gen_random_uuid(), 'Quota Race HH', 'Owner')->>'household_id');")
MONTH=$(psql_svc "select date_trunc('month', now())::date;")
# Other test files (e.g. tests/sql/05_line_quota_reservation.sql) may have
# left active/ambiguous reservations for this same real-world billing month;
# clear them so this race starts from a known, isolated quota state.
psql_svc "update private.notification_outbox set quota_reservation_id = null where quota_reservation_id in (select id from private.line_quota_reservations where billing_month = '$MONTH'); delete from private.line_quota_reservations where billing_month = '$MONTH';" >/dev/null
psql_svc "insert into private.line_quota_state (billing_month, provider_limit, provider_consumed, soft_budget, reserve) values ('$MONTH', 200, 179, 180, 20) on conflict (billing_month) do update set provider_limit=200, provider_consumed=179, local_counted_success=0, soft_budget=180, reserve=20;" >/dev/null

make_outbox() {
  local priority="${1:-normal}"
  psql_svc "insert into private.notification_outbox (household_id, recipient_user_id, channel, type, payload, dedup_key, priority) values ('$QHH','$QUOTA_OWNER','line','test','{}'::jsonb, '$(uuidgen)', '$priority') returning id;"
}
OUT1=$(make_outbox reminder)
OUT2=$(make_outbox reminder)

run_reserve() {
  local outbox="$1" priority="$2" outfile="$3"
  psql -v ON_ERROR_STOP=1 -d "$TEST_DB" -q -t -A <<SQL > "$outfile" 2>&1 &
set role service_role;
select pg_sleep(random() * 0.2);
select public.server_tx_reserve_line_quota('$outbox', '$priority')::text;
SQL
}

R1=$(mktemp); R2=$(mktemp)
run_reserve "$OUT1" "reminder" "$R1"
run_reserve "$OUT2" "reminder" "$R2"
wait

PERMITS=0
grep -q '"permitted": true' "$R1" && PERMITS=$((PERMITS + 1))
grep -q '"permitted": true' "$R2" && PERMITS=$((PERMITS + 1))
[ "$PERMITS" -eq 1 ] || { cat "$R1" "$R2"; fail "LQA01: two parallel reminder reservations at provider_consumed=179 must yield exactly one permit (soft budget 180), got $PERMITS"; }
echo "OK: LQA01 — parallel reminders at 179 obey the soft budget race (exactly one permit)"

psql_svc "update private.notification_outbox set quota_reservation_id = null where quota_reservation_id in (select id from private.line_quota_reservations where billing_month = '$MONTH'); delete from private.line_quota_reservations where billing_month = '$MONTH';" >/dev/null
psql_svc "update private.line_quota_state set provider_consumed=199, local_counted_success=0, soft_budget=180, reserve=20 where billing_month='$MONTH';" >/dev/null
OUT3=$(make_outbox critical)
OUT4=$(make_outbox critical)
R3=$(mktemp); R4=$(mktemp)
run_reserve "$OUT3" "critical" "$R3"
run_reserve "$OUT4" "critical" "$R4"
wait

PERMITS2=0
grep -q '"permitted": true' "$R3" && PERMITS2=$((PERMITS2 + 1))
grep -q '"permitted": true' "$R4" && PERMITS2=$((PERMITS2 + 1))
[ "$PERMITS2" -eq 1 ] || { cat "$R3" "$R4"; fail "LQA02: two parallel critical reservations at provider_consumed=199 must yield at most one permit, got $PERMITS2"; }
echo "OK: LQA02 — parallel critical reservations at 199 yield at most one permit"

echo "== all concurrency tests passed =="
