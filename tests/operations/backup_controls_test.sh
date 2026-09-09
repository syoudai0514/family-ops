#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FRESHNESS="$ROOT/scripts/backup_freshness_check.sh"
RESTORE="$ROOT/scripts/restore_drill.sh"
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
write_marker "family-ops-backup-$(date -u +%Y-%m-%d).sql.age" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAKE_OBJECT_PRESENT=1 FAKE_OBJECT_SIZE=4096 run_freshness >/dev/null

# A fresh marker pointing at a missing object must be RED.
FAKE_OBJECT_PRESENT=0 expect_status 1 run_freshness

# An empty object must also be RED.
FAKE_OBJECT_PRESENT=1 FAKE_OBJECT_SIZE=0 expect_status 1 run_freshness

# Stale marker must fail freshness policy.
write_marker "family-ops-backup-$(date -u -d '2 days ago' +%Y-%m-%d).sql.age" "$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)"
expect_status 1 run_freshness

# A marker materially in the future must not pass via a negative age.
write_marker "family-ops-backup-$(date -u +%Y-%m-%d).sql.age" "$(date -u -d '2 hours' +%Y-%m-%dT%H:%M:%SZ)"
expect_status 1 run_freshness

# Marker object names are constrained to the backup naming contract.
write_marker "not-a-backup.sql.age" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
expect_status 1 run_freshness

# Restore drills must stay human/local. CI refusal happens before any secret,
# R2, age, psql, or network access is attempted.
expect_status 3 env CI=true PATH="$PATH" bash "$RESTORE" --scratch-db-url "postgresql://unused/unused"

# Help remains safe and available without credentials.
bash "$RESTORE" --help >/dev/null

# Syntax checks catch accidental shell regressions in both operational scripts.
bash -n "$FRESHNESS"
bash -n "$RESTORE"

echo "PASS: backup operational control regression tests"
