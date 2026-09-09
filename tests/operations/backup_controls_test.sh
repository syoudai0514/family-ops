#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP="$ROOT/.github/workflows/backup.yml"
FRESHNESS_WORKFLOW="$ROOT/.github/workflows/backup_freshness_alert.yml"
DRILL_WORKFLOW="$ROOT/.github/workflows/recovery-drill.yml"
SNAPSHOT="$ROOT/scripts/create_household_snapshot.sh"
FRESHNESS="$ROOT/scripts/backup_freshness_check.sh"
RESTORE="$ROOT/scripts/restore_drill.sh"
TABLES="$ROOT/scripts/family_ops_recovery_tables.txt"
ADR="$ROOT/docs/adr/0014-right-sized-household-backup-recovery.md"
DESIGN="$ROOT/docs/design/current/10_BACKUP_RECOVERY.md"
RUNBOOK="$ROOT/docs/BACKUP_RESTORE_RUNBOOK.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_status() {
  local expected="$1"; shift
  set +e
  "$@" >/dev/null 2>&1
  local actual=$?
  set -e
  [ "$actual" -eq "$expected" ] || fail "expected exit $expected, got $actual: $*"
}

for file in "$BACKUP" "$FRESHNESS_WORKFLOW" "$DRILL_WORKFLOW" "$SNAPSHOT" "$FRESHNESS" "$RESTORE" "$TABLES" "$ADR" "$DESIGN" "$RUNBOOK"; do
  [ -s "$file" ] || fail "required CF-11 file missing: $file"
done

bash -n "$SNAPSHOT"
bash -n "$FRESHNESS"
bash -n "$RESTORE"
bash "$RESTORE" --help >/dev/null
expect_status 3 bash "$RESTORE" --scratch-db-url 'postgresql://user:pw@example.invalid/db'

# CURRENT implementation must not retain the legacy R2/age secret/key path.
for file in "$BACKUP" "$FRESHNESS_WORKFLOW" "$DRILL_WORKFLOW" "$SNAPSHOT" "$FRESHNESS" "$RESTORE"; do
  if grep -Eq 'R2_(ACCOUNT|ACCESS|SECRET|BUCKET)|BACKUP_AGE|AGE_PRIVATE_KEY|cloudflarestorage\.com|aws s3|age -[rd]' "$file"; then
    fail "legacy R2/age implementation reference remains in $file"
  fi
done
if grep -Rq 'actions/upload-artifact' "$BACKUP" "$DRILL_WORKFLOW"; then
  fail "household recovery payload must not be uploaded as a GitHub artifact"
fi

# Existing services only: one known source and the already-existing separate
# app-save-hub target, using the already-configured management token.
grep -Fq 'SOURCE_PROJECT_REF: dnlqxjpjpkxnfgculzip' "$BACKUP" || fail "backup source project ref missing"
grep -Fq 'TARGET_PROJECT_REF: wdwbmvpipbdpomqulsrj' "$BACKUP" || fail "app-save-hub target project ref missing"
grep -Fq 'SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}' "$BACKUP" || fail "existing Supabase token is not used"
grep -Fq 'MAX_BACKUPS: "30"' "$BACKUP" || fail "30-snapshot retention contract missing"
grep -Fq 'cmp -s "$WORKDIR/source-canonical.json" "$WORKDIR/target-canonical.json"' "$SNAPSHOT" || fail "full payload read-back equality check missing"
grep -Fq "app_id = 'family-ops'" "$SNAPSHOT" || fail "Family Ops history isolation filter missing"
grep -Fq "slot_id = 'household'" "$SNAPSHOT" || fail "Family Ops household slot isolation missing"

# Allowlist must be explicit, public-domain only, duplicate-free and contain the
# currently foundational household/task/routine/transport state.
mapfile -t RECOVERY_TABLES < <(sed -E 's/[[:space:]]+#.*$//' "$TABLES" | sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d')
[ "${#RECOVERY_TABLES[@]}" -ge 20 ] || fail "recovery allowlist is implausibly small"
[ "$(printf '%s\n' "${RECOVERY_TABLES[@]}" | sort | uniq -d | wc -l)" -eq 0 ] || fail "recovery allowlist has duplicate tables"
for table in "${RECOVERY_TABLES[@]}"; do
  [[ "$table" =~ ^public\.[a-z][a-z0-9_]*$ ]] || fail "invalid/non-public recovery table: $table"
done
for required in \
  public.households public.profiles public.household_members public.domain_actor_refs \
  public.task_definitions public.task_instances public.task_subtask_instances \
  public.recurrence_rules public.shopping_items public.handovers \
  public.household_routine_schedules public.routine_checkin_sessions \
  public.transport_weekly_templates; do
  grep -Fxq "$required" "$TABLES" || fail "foundational recovery table missing: $required"
done
for prohibited in \
  public.test_simulation_contexts public.calendar_connections public.calendar_events_cache \
  public.user_notifications; do
  if grep -Fxq "$prohibited" "$TABLES"; then
    fail "derived/provider/test table must not be household recovery truth: $prohibited"
  fi
done
if grep -Eq '^private\.' "$TABLES"; then
  fail "private operational/provider tables must not be in the CF-11 household snapshot"
fi

grep -Fq 'test_context_id is null' "$SNAPSHOT" || fail "test/simulation row filtering missing"
grep -Fq "jsonb_build_object('id', u.id, 'email', u.email)" "$SNAPSHOT" || fail "minimal Auth ownership refs missing"
if grep -Eq 'encrypted_password|refresh_token|raw_user_meta_data|auth\.identities' "$SNAPSHOT"; then
  fail "snapshot producer must not copy Auth credentials/session/provider identity data"
fi

# Recovery proof must use an actual disposable Supabase stack and typed restore,
# while daily scheduled backups must not create a daily restore stack.
grep -Fq 'workflow_run:' "$DRILL_WORKFLOW" || fail "recovery drill must follow a successful backup"
grep -Fq "github.event.workflow_run.event == 'push'" "$DRILL_WORKFLOW" || fail "automatic recovery drill must be limited to main push evidence"
if grep -Fq 'schedule:' "$DRILL_WORKFLOW"; then
  fail "right-sized recovery drill must not run a disposable stack every day"
fi
grep -Fq 'supabase db reset' "$DRILL_WORKFLOW" || fail "disposable current-schema setup missing"
grep -Fq 'jsonb_populate_recordset' "$RESTORE" || fail "typed table restore missing"
grep -Fq 'snapshot table set does not exactly match' "$RESTORE" || fail "allowlist/table-set equality guard missing"
grep -Fq 'restored row count mismatch' "$RESTORE" || fail "exact per-table row count validation missing"

# Architecture governance must explicitly supersede only legacy CF-11 mechanics,
# not silently call an unexecuted v6 design PASS.
grep -Fq 'supersedes only the CF-11 backup/recovery implementation mechanics' "$ADR" || fail "ADR authority resolution missing"
grep -Fq 'R2, age encryption and an' "$ADR" || fail "ADR must state R2/age are not CURRENT acceptance"
grep -Fq 'CF-11 = PASS only with CURRENT operational evidence' "$DESIGN" || fail "CURRENT acceptance gate missing"
grep -Fq 'Actual disposable recovery drill SUCCESS' "$RUNBOOK" || fail "runbook live recovery proof gate missing"

# Unit-regress exact freshness boundary without accessing Supabase.
cat > "$TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
cat <<JSON
[{"updated_at":"${FAKE_STORED_AT}","source_created_at":"${FAKE_SOURCE_AT}","source_project_ref":"${FAKE_SOURCE_REF:-dnlqxjpjpkxnfgculzip}","schema_version":"${FAKE_SCHEMA_VERSION:-1}","tables_type":"${FAKE_TABLES_TYPE:-object}","households":${FAKE_HOUSEHOLDS:-1},"household_members":${FAKE_MEMBERS:-1},"task_instances":${FAKE_TASKS:-1}}]
JSON
FAKE_CURL
chmod +x "$TMP/bin/curl"

timestamp_seconds_ago() {
  local seconds="$1"
  date -u -d "@$(( $(date -u +%s) - seconds ))" +%Y-%m-%dT%H:%M:%SZ
}

run_freshness() {
  env \
    PATH="$TMP/bin:$PATH" \
    SUPABASE_ACCESS_TOKEN=test-token \
    TARGET_PROJECT_REF=target-test \
    SOURCE_PROJECT_REF=dnlqxjpjpkxnfgculzip \
    MAX_BACKUP_AGE_HOURS=26 \
    FAKE_STORED_AT="${FAKE_STORED_AT}" \
    FAKE_SOURCE_AT="${FAKE_SOURCE_AT}" \
    FAKE_SOURCE_REF="${FAKE_SOURCE_REF:-dnlqxjpjpkxnfgculzip}" \
    FAKE_SCHEMA_VERSION="${FAKE_SCHEMA_VERSION:-1}" \
    FAKE_TABLES_TYPE="${FAKE_TABLES_TYPE:-object}" \
    FAKE_HOUSEHOLDS="${FAKE_HOUSEHOLDS:-1}" \
    FAKE_MEMBERS="${FAKE_MEMBERS:-1}" \
    FAKE_TASKS="${FAKE_TASKS:-1}" \
    bash "$FRESHNESS"
}

FAKE_STORED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAKE_SOURCE_AT="$(timestamp_seconds_ago $((25 * 3600 + 55 * 60)))"
run_freshness >/dev/null

FAKE_STORED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAKE_SOURCE_AT="$(timestamp_seconds_ago $((26 * 3600 + 5 * 60)))"
expect_status 1 run_freshness

FAKE_STORED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAKE_SOURCE_AT="$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)"
expect_status 1 run_freshness

FAKE_STORED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAKE_SOURCE_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAKE_TASKS=0 expect_status 1 run_freshness

# Required status-check job identity must stay stable for the protected ruleset.
grep -Fq 'name: operational-safety (backup controls)' "$ROOT/.github/workflows/operational-safety-ci.yml" || fail "protected operational-safety check name changed"

echo "PASS: right-sized CF-11 backup/recovery control regressions"
