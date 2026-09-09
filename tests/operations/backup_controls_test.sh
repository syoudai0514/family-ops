#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FRESHNESS="$ROOT/scripts/backup_freshness_check.sh"
RESTORE="$ROOT/scripts/restore_drill.sh"
BACKUP_WORKFLOW="$ROOT/.github/workflows/backup.yml"
RECOVERY_WORKERS="$ROOT/scripts/reconfigure_recovery_workers.sql"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/aws" <<'FAKE_AWS'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "s3" ] && [ "${2:-}" = "cp" ]; then
  src="${3:-}"
  dst="${4:-}"
  if [[ "$src" == */latest-backup.txt ]]; then
    cp "$FAKE_MARKER_FILE" "$dst"
    exit 0
  fi
fi
if [ "${1:-}" = "s3api" ] && [ "${2:-}" = "head-object" ]; then
  if [ "${FAKE_OBJECT_PRESENT:-1}" = "1" ]; then
    printf '%s\n' "${FAKE_OBJECT_SIZE:-1024}"
    exit 0
  fi
  exit 1
fi
echo "unexpected fake aws invocation: $*" >&2
exit 99
FAKE_AWS
chmod +x "$TMP/bin/aws"

BASE_PATH="$TMP/bin:$PATH"

write_marker() {
  local filename="$1"
  local timestamp="$2"
  printf '%s\n%s\n' "$filename" "$timestamp" > "$TMP/marker.txt"
}

timestamp_seconds_ago() {
  local seconds="$1"
  date -u -d "@$(( $(date -u +%s) - seconds ))" +%Y-%m-%dT%H:%M:%SZ
}

run_freshness() {
  env \
    PATH="$BASE_PATH" \
    HOME="${HOME:-$TMP}" \
    R2_ACCOUNT_ID="test-account" \
    R2_BUCKET_NAME="test-bucket" \
    AWS_ACCESS_KEY_ID="test-access" \
    AWS_SECRET_ACCESS_KEY="test-secret" \
    FAKE_MARKER_FILE="$TMP/marker.txt" \
    FAKE_OBJECT_PRESENT="${FAKE_OBJECT_PRESENT:-1}" \
    FAKE_OBJECT_SIZE="${FAKE_OBJECT_SIZE:-1024}" \
    MAX_BACKUP_AGE_HOURS="${MAX_BACKUP_AGE_HOURS:-26}" \
    bash "$FRESHNESS"
}

expect_status() {
  local expected="$1"
  shift
  set +e
  "$@" >/dev/null 2>&1
  local actual=$?
  set -e
  if [ "$actual" -ne "$expected" ]; then
    echo "FAIL: expected exit $expected, got $actual: $*" >&2
    exit 1
  fi
}

expect_status 2 env PATH="$BASE_PATH" bash "$FRESHNESS"

write_marker "family-ops-backup-$(date -u +%Y-%m-%d).tar.age" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAKE_OBJECT_PRESENT=1 FAKE_OBJECT_SIZE=4096 run_freshness >/dev/null

write_marker "family-ops-backup-$(date -u +%Y-%m-%d).tar.age" "$(timestamp_seconds_ago $((25 * 3600 + 55 * 60)))"
run_freshness >/dev/null
write_marker "family-ops-backup-$(date -u +%Y-%m-%d).tar.age" "$(timestamp_seconds_ago $((26 * 3600 + 5 * 60)))"
expect_status 1 run_freshness

write_marker "family-ops-backup-$(date -u +%Y-%m-%d).tar.age" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAKE_OBJECT_PRESENT=0 expect_status 1 run_freshness
FAKE_OBJECT_PRESENT=1 FAKE_OBJECT_SIZE=0 expect_status 1 run_freshness

write_marker "family-ops-backup-$(date -u -d '2 days ago' +%Y-%m-%d).tar.age" "$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)"
expect_status 1 run_freshness

write_marker "family-ops-backup-$(date -u +%Y-%m-%d).tar.age" "$(date -u -d '2 hours' +%Y-%m-%dT%H:%M:%SZ)"
expect_status 1 run_freshness

write_marker "not-a-backup.tar.age" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
expect_status 1 run_freshness

if grep -Eq '^[[:space:]]+pg_dump[[:space:]\\]' "$BACKUP_WORKFLOW"; then
  echo "FAIL: backup.yml must not run raw pg_dump against the Supabase managed cluster" >&2
  exit 1
fi
if ! grep -q 'uses: supabase/setup-cli@v1' "$BACKUP_WORKFLOW"; then
  echo "FAIL: backup.yml must install Supabase CLI via setup-cli" >&2
  exit 1
fi
if ! grep -q 'version: 2.115.0' "$BACKUP_WORKFLOW"; then
  echo "FAIL: backup.yml must use the Supabase CLI version already proven by Family Ops integration CI" >&2
  exit 1
fi
for required in \
  'supabase db dump --db-url "$SUPABASE_DB_URL" -f roles.sql --role-only' \
  'supabase db dump --db-url "$SUPABASE_DB_URL" -f schema.sql' \
  '--data-only --use-copy' \
  '--schema supabase_migrations' \
  'tar -cf logical-backup.tar'; do
  if ! grep -Fq -- "$required" "$BACKUP_WORKFLOW"; then
    echo "FAIL: backup.yml is missing Supabase-compatible backup contract: $required" >&2
    exit 1
  fi
done

for excluded in \
  '-x "cron.job"' \
  '-x "cron.job_run_details"' \
  '-x "net.http_request_queue"' \
  '-x "net._http_response"'; do
  if ! grep -Fq -- "$excluded" "$BACKUP_WORKFLOW"; then
    echo "FAIL: backup.yml must exclude environment-specific worker state: $excluded" >&2
    exit 1
  fi
done

HEAD_OBJECT_LINE="$(grep -n 'aws s3api head-object' "$BACKUP_WORKFLOW" | head -n1 | cut -d: -f1 || true)"
MARKER_STEP_LINE="$(grep -n 'name: Update latest-backup marker' "$BACKUP_WORKFLOW" | head -n1 | cut -d: -f1 || true)"
if [ -z "$HEAD_OBJECT_LINE" ] || [ -z "$MARKER_STEP_LINE" ] || [ "$HEAD_OBJECT_LINE" -ge "$MARKER_STEP_LINE" ]; then
  echo "FAIL: backup.yml must verify R2 head-object before the marker-update step" >&2
  exit 1
fi

if grep -REn 'AGE_PRIVATE_KEY|AGE-SECRET-KEY' "$ROOT/.github/workflows" >/dev/null; then
  echo "FAIL: private age key material/identifier must not appear in CI workflows" >&2
  exit 1
fi
if ! grep -q 'BACKUP_AGE_PUBLIC_KEY' "$BACKUP_WORKFLOW"; then
  echo "FAIL: backup.yml must encrypt using BACKUP_AGE_PUBLIC_KEY" >&2
  exit 1
fi

for required in \
  "to_regnamespace('auth')" \
  "to_regnamespace('storage')" \
  "to_regrole('service_role')" \
  "to_regclass('cron.job')" \
  "to_regclass('net.http_request_queue')" \
  "to_regclass('vault.decrypted_secrets')" \
  'history_schema.sql' \
  'history_data.sql' \
  'EXPECTED_MEMBERS=' \
  'SET session_replication_role = replica' \
  '--single-transaction' \
  'select count(*) from auth.users' \
  'select count(*) from auth.identities' \
  'MEMBER_AUTH_ORPHANS=' \
  'PROFILE_AUTH_ORPHANS=' \
  'MEMBER_IDENTITY_ORPHANS=' \
  'FAMILY_OPS_CRON_JOBS='; do
  if ! grep -Fq -- "$required" "$RESTORE"; then
    echo "FAIL: restore drill is missing Supabase-compatible recovery guard: $required" >&2
    exit 1
  fi
done

test -s "$RECOVERY_WORKERS" || { echo "FAIL: recovery worker SQL is missing" >&2; exit 1; }
for required in \
  'vault.decrypted_secrets' \
  'family_ops_project_url' \
  'family_ops_worker_token' \
  'X-Family-Ops-Worker-Token' \
  'family-ops-calendar-outbox-v1' \
  'process-family-ops-calendar-outbox' \
  'family-ops-line-delivery-v1' \
  'send-notifications' \
  'family-ops-line-inbox-v1' \
  'process-line-inbox' \
  'family-ops-materialize-recurring-v1' \
  'materialize-recurring' \
  'family-ops-pending-actions-v1' \
  'process-pending-actions' \
  'family-ops-routine-dispatch-v1' \
  'dispatch-routine-automation' \
  '10 15 * * *'; do
  if ! grep -Fq -- "$required" "$RECOVERY_WORKERS"; then
    echo "FAIL: recovery worker SQL is missing contract element: $required" >&2
    exit 1
  fi
done
if [ "$(grep -c 'SELECT cron.schedule(' "$RECOVERY_WORKERS")" -ne 6 ]; then
  echo "FAIL: recovery worker SQL must define exactly six Family Ops jobs" >&2
  exit 1
fi
if grep -Fq 'dnlqxjpjpkxnfgculzip' "$RECOVERY_WORKERS"; then
  echo "FAIL: recovery worker SQL must not hardcode the production Supabase project ref" >&2
  exit 1
fi
if grep -Eq 'CRON_WORKER_TOKEN[[:space:]]*=' "$RECOVERY_WORKERS"; then
  echo "FAIL: recovery worker SQL must not contain a literal worker-token assignment" >&2
  exit 1
fi

expect_status 3 env CI=true PATH="$PATH" bash "$RESTORE" --scratch-db-url "postgresql://unused/unused"
bash "$RESTORE" --help >/dev/null
bash -n "$FRESHNESS"
bash -n "$RESTORE"

echo "PASS: backup operational control regression tests"
