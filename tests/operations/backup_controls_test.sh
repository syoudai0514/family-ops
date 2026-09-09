#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FRESHNESS="$ROOT/scripts/backup_freshness_check.sh"
RESTORE="$ROOT/scripts/restore_drill.sh"
BACKUP_WORKFLOW="$ROOT/.github/workflows/backup.yml"
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

# Missing configuration must fail before any R2 call.
expect_status 2 env PATH="$BASE_PATH" bash "$FRESHNESS"

# Fresh marker + non-empty referenced object is the only success case.
write_marker "family-ops-backup-$(date -u +%Y-%m-%d).tar.age" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAKE_OBJECT_PRESENT=1 FAKE_OBJECT_SIZE=4096 run_freshness >/dev/null

# The 26-hour policy is exact. A marker just inside the limit passes, while a
# marker more than 26 hours old must fail even though floor-truncated hours
# would still display as 26.
write_marker "family-ops-backup-$(date -u +%Y-%m-%d).tar.age" "$(timestamp_seconds_ago $((25 * 3600 + 55 * 60)))"
run_freshness >/dev/null
write_marker "family-ops-backup-$(date -u +%Y-%m-%d).tar.age" "$(timestamp_seconds_ago $((26 * 3600 + 5 * 60)))"
expect_status 1 run_freshness

# A fresh marker pointing at a missing object must be RED.
write_marker "family-ops-backup-$(date -u +%Y-%m-%d).tar.age" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAKE_OBJECT_PRESENT=0 expect_status 1 run_freshness

# An empty object must also be RED.
FAKE_OBJECT_PRESENT=1 FAKE_OBJECT_SIZE=0 expect_status 1 run_freshness

# Stale marker must fail freshness policy.
write_marker "family-ops-backup-$(date -u -d '2 days ago' +%Y-%m-%d).tar.age" "$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)"
expect_status 1 run_freshness

# A marker materially in the future must not pass via a negative age.
write_marker "family-ops-backup-$(date -u +%Y-%m-%d).tar.age" "$(date -u -d '2 hours' +%Y-%m-%dT%H:%M:%SZ)"
expect_status 1 run_freshness

# Marker object names are constrained to the encrypted bundle contract.
write_marker "not-a-backup.tar.age" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
expect_status 1 run_freshness

# Supabase production backups must use the Supabase CLI's filtered logical
# dump path. Raw pg_dump of the whole managed cluster can include Supabase
# internals and is not the recovery contract.
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

# A backup run must verify the encrypted R2 object before it is allowed to
# advance latest-backup.txt.
HEAD_OBJECT_LINE="$(grep -n 'aws s3api head-object' "$BACKUP_WORKFLOW" | head -n1 | cut -d: -f1 || true)"
MARKER_STEP_LINE="$(grep -n 'name: Update latest-backup marker' "$BACKUP_WORKFLOW" | head -n1 | cut -d: -f1 || true)"
if [ -z "$HEAD_OBJECT_LINE" ] || [ -z "$MARKER_STEP_LINE" ] || [ "$HEAD_OBJECT_LINE" -ge "$MARKER_STEP_LINE" ]; then
  echo "FAIL: backup.yml must verify R2 head-object before the marker-update step" >&2
  exit 1
fi

# CI may hold only the age public recipient. Known private-key identifiers must
# never creep into workflow files.
if grep -REn 'AGE_PRIVATE_KEY|AGE-SECRET-KEY' "$ROOT/.github/workflows" >/dev/null; then
  echo "FAIL: private age key material/identifier must not appear in CI workflows" >&2
  exit 1
fi
if ! grep -q 'BACKUP_AGE_PUBLIC_KEY' "$BACKUP_WORKFLOW"; then
  echo "FAIL: backup.yml must encrypt using BACKUP_AGE_PUBLIC_KEY" >&2
  exit 1
fi

# Restore must target a fresh Supabase-compatible environment, validate the
# bundle members, preserve migration history, and disable triggers only for
# the data phase as recommended by Supabase's logical restore procedure.
for required in \
  "to_regnamespace('auth')" \
  "to_regnamespace('storage')" \
  "to_regrole('service_role')" \
  'history_schema.sql' \
  'history_data.sql' \
  'EXPECTED_MEMBERS=' \
  'SET session_replication_role = replica' \
  '--single-transaction'; do
  if ! grep -Fq -- "$required" "$RESTORE"; then
    echo "FAIL: restore drill is missing Supabase-compatible restore guard: $required" >&2
    exit 1
  fi
done

# Restore drills must stay human/local. CI refusal happens before any secret,
# R2, age, psql, or network access is attempted.
expect_status 3 env CI=true PATH="$PATH" bash "$RESTORE" --scratch-db-url "postgresql://unused/unused"

# Help remains safe and available without credentials.
bash "$RESTORE" --help >/dev/null

# Syntax checks catch accidental shell regressions in operational scripts.
bash -n "$FRESHNESS"
bash -n "$RESTORE"

echo "PASS: backup operational control regression tests"
