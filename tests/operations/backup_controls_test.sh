#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP="$ROOT/.github/workflows/backup.yml"
FRESHNESS_WORKFLOW="$ROOT/.github/workflows/backup_freshness_alert.yml"
DRILL_WORKFLOW="$ROOT/.github/workflows/recovery-drill.yml"
SNAPSHOT="$ROOT/scripts/create_household_snapshot.sh"
FRESHNESS="$ROOT/scripts/backup_freshness_check.sh"
PREPARE_AUTH="$ROOT/scripts/prepare_recovery_auth_smoke.sh"
RESTORE="$ROOT/scripts/restore_drill.sh"
VERIFY_ACCESS="$ROOT/scripts/verify_recovery_access.sh"
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

for file in "$BACKUP" "$FRESHNESS_WORKFLOW" "$DRILL_WORKFLOW" "$SNAPSHOT" "$FRESHNESS" "$PREPARE_AUTH" "$RESTORE" "$VERIFY_ACCESS" "$TABLES" "$ADR" "$DESIGN" "$RUNBOOK"; do
  [ -s "$file" ] || fail "required CF-11 file missing: $file"
done

for script in "$SNAPSHOT" "$FRESHNESS" "$PREPARE_AUTH" "$RESTORE" "$VERIFY_ACCESS"; do
  bash -n "$script" || fail "shell syntax invalid: $script"
done
bash "$PREPARE_AUTH" --help >/dev/null
bash "$RESTORE" --help >/dev/null
bash "$VERIFY_ACCESS" --help >/dev/null

# CURRENT right-size implementation must not retain the legacy R2/age secret path.
# Do not match ordinary freshness variables such as MAX_BACKUP_AGE_HOURS.
for file in "$BACKUP" "$FRESHNESS_WORKFLOW" "$DRILL_WORKFLOW" "$SNAPSHOT" "$FRESHNESS" "$PREPARE_AUTH" "$RESTORE" "$VERIFY_ACCESS"; do
  if grep -Eq 'R2_(ACCOUNT|ACCESS|SECRET|BUCKET)|BACKUP_AGE_(PUBLIC|PRIVATE)_KEY|AGE_PRIVATE_KEY|cloudflarestorage\.com|aws s3|age -[rd]' "$file"; then
    fail "legacy R2/age implementation reference remains in $file"
  fi
done
if grep -Rq 'actions/upload-artifact' "$BACKUP" "$DRILL_WORKFLOW"; then
  fail "household recovery payload/session must not be uploaded as an artifact"
fi

# Existing services and explicit app-save-hub namespace only.
grep -Fq 'SOURCE_PROJECT_REF: dnlqxjpjpkxnfgculzip' "$BACKUP" || fail "backup source ref missing"
grep -Fq 'TARGET_PROJECT_REF: wdwbmvpipbdpomqulsrj' "$BACKUP" || fail "app-save-hub target ref missing"
grep -Fq 'SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}' "$BACKUP" || fail "existing Supabase token missing"
grep -Fq 'MAX_BACKUPS: "30"' "$BACKUP" || fail "30-generation retention missing"
for file in "$SNAPSHOT" "$FRESHNESS" "$PREPARE_AUTH" "$RESTORE"; do
  grep -Fq 'family-ops-recovery-v1' "$file" || fail "reserved Family Ops app_id missing in $file"
  grep -Fq 'household-durable-v1' "$file" || fail "reserved Family Ops slot_id missing in $file"
done
grep -Fq 'cmp -s "$WORKDIR/source-canonical.json" "$WORKDIR/target-canonical.json"' "$SNAPSHOT" || fail "full read-back equality missing"
grep -Fq "where user_id='\${OWNER_USER_ID}'::uuid and app_id='\${APP_ID}' and slot_id='\${SLOT_ID}'" "$SNAPSHOT" || fail "revision selection is not owner/app/slot scoped"
grep -Fq "b.user_id='\${OWNER_USER_ID}'::uuid" "$SNAPSHOT" || fail "retention prune is not owner-scoped"
grep -Fq 'relrowsecurity' "$SNAPSHOT" || fail "app-save-hub RLS preflight missing"
grep -Fq 'foreign_namespace_rows' "$SNAPSHOT" || fail "namespace owner conflict guard missing"

# Allowlist is explicit durable public-domain truth only.
mapfile -t RECOVERY_TABLES < <(sed -E 's/[[:space:]]+#.*$//' "$TABLES" | sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d')
[ "${#RECOVERY_TABLES[@]}" -ge 20 ] || fail "recovery allowlist is implausibly small"
[ "$(printf '%s\n' "${RECOVERY_TABLES[@]}" | sort | uniq -d | wc -l)" -eq 0 ] || fail "recovery allowlist duplicates"
for table in "${RECOVERY_TABLES[@]}"; do
  [[ "$table" =~ ^public\.[a-z][a-z0-9_]*$ ]] || fail "invalid/non-public recovery table: $table"
done
for required in public.households public.profiles public.household_members public.domain_actor_refs public.task_definitions public.task_instances public.task_subtask_instances public.recurrence_rules public.shopping_items public.handovers public.household_routine_schedules public.routine_checkin_sessions public.transport_weekly_templates; do
  grep -Fxq "$required" "$TABLES" || fail "foundational recovery table missing: $required"
done
for prohibited in public.test_simulation_contexts public.calendar_connections public.calendar_events_cache public.user_notifications; do
  ! grep -Fxq "$prohibited" "$TABLES" || fail "derived/provider/test table in recovery truth: $prohibited"
done
! grep -Eq '^private\.' "$TABLES" || fail "private provider/queue tables must not be snapshotted"
grep -Fq 'test_context_id is null' "$SNAPSHOT" || fail "test row filtering missing"
grep -Fq "'email', lower(u.email)" "$SNAPSHOT" || fail "minimal Auth email mapping refs missing"
if grep -Eq 'encrypted_password|refresh_token|raw_user_meta_data|auth\.identities' "$SNAPSHOT"; then
  fail "snapshot producer must not copy Auth credential/session/provider identity data"
fi

# Recovery proof must happen pre-merge on same-repo PR and prove real sign-in,
# schema-derived UUID rebinding and RLS access — not placeholder Auth rows.
grep -Fq 'pull_request:' "$DRILL_WORKFLOW" || fail "pre-merge recovery evidence trigger missing"
grep -Fq 'bash scripts/create_household_snapshot.sh' "$DRILL_WORKFLOW" || fail "PR evidence does not create actual backup"
grep -Fq 'bash scripts/backup_freshness_check.sh' "$DRILL_WORKFLOW" || fail "PR evidence freshness missing"
grep -Fq 'prepare_recovery_auth_smoke.sh' "$DRILL_WORKFLOW" || fail "real Auth sign-in preparation missing"
grep -Fq 'verify_recovery_access.sh' "$DRILL_WORKFLOW" || fail "authenticated recovery access proof missing"
! grep -Fq 'schedule:' "$DRILL_WORKFLOW" || fail "disposable restore stack must not run daily"
grep -Fq 'supabase db reset' "$DRILL_WORKFLOW" || fail "disposable schema setup missing"
grep -Fq '/auth/v1/admin/users' "$PREPARE_AUTH" || fail "new Auth user creation boundary missing"
grep -Fq '/auth/v1/token?grant_type=password' "$PREPARE_AUTH" || fail "real GoTrue sign-in proof missing"
if grep -Fq 'insert into auth.users' "$RESTORE"; then
  fail "restore drill must not fake production Auth rows"
fi
grep -Fq 'generate_subscripts(c.conkey,1)' "$RESTORE" || fail "schema-derived identity FK discovery missing"
grep -Fq "parent_ns.nspname='auth'" "$RESTORE" || fail "auth.users FK discovery missing"
grep -Fq "parent.relname='household_members'" "$RESTORE" || fail "household member user-FK discovery missing"
grep -Fq 'jsonb_populate_recordset' "$RESTORE" || fail "typed restore missing"
grep -Fq 'row-count mismatch' "$RESTORE" || fail "exact row-count validation missing"
grep -Fq 'source-field content mismatch' "$RESTORE" || fail "restored source-field equality proof missing"
grep -Fq 'migration identifiers differ' "$RESTORE" || fail "migration-id drift handling is not explicit"
grep -Fq 'stale production user UUID remains' "$RESTORE" || fail "old UUID elimination proof missing"
grep -Fq 'profiles?user_id=eq.' "$VERIFY_ACCESS" || fail "profile RLS proof missing"
grep -Fq 'household_members?user_id=eq.' "$VERIFY_ACCESS" || fail "membership RLS proof missing"
grep -Fq 'households?id=eq.' "$VERIFY_ACCESS" || fail "household RLS proof missing"
grep -Fq 'task_instances?household_id=eq.' "$VERIFY_ACCESS" || fail "task RLS proof missing"

# Governance: Product Owner approved, but not Accepted/canonical before merge.
grep -Fq '**Status:** Product Owner approved / pending canonical merge' "$ADR" || fail "ADR0014 premature canonical status"
grep -Fq 'After this ADR is merged and becomes Accepted' "$ADR" || fail "ADR0012 merge authority boundary missing"
grep -Fq 'pending canonical merge' "$DESIGN" || fail "design must remain non-canonical before merge"
grep -Fq 'Usable identity recovery' "$DESIGN" || fail "usable family recovery gate missing"

# Unit-regress exact freshness boundary without accessing Supabase.
cat > "$TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
cat <<JSON
[{"updated_at":"${FAKE_STORED_AT}","source_created_at":"${FAKE_SOURCE_AT}","source_project_ref":"${FAKE_SOURCE_REF:-dnlqxjpjpkxnfgculzip}","schema_version":"${FAKE_SCHEMA_VERSION:-1}","namespace_app_id":"${FAKE_APP_ID:-family-ops-recovery-v1}","namespace_slot_id":"${FAKE_SLOT_ID:-household-durable-v1}","tables_type":"${FAKE_TABLES_TYPE:-object}","households":${FAKE_HOUSEHOLDS:-1},"household_members":${FAKE_MEMBERS:-1},"task_instances":${FAKE_TASKS:-1}}]
JSON
FAKE_CURL
chmod +x "$TMP/bin/curl"

timestamp_seconds_ago() { local seconds="$1"; date -u -d "@$(( $(date -u +%s) - seconds ))" +%Y-%m-%dT%H:%M:%SZ; }
run_freshness() {
  env PATH="$TMP/bin:$PATH" SUPABASE_ACCESS_TOKEN=test-token TARGET_PROJECT_REF=target-test SOURCE_PROJECT_REF=dnlqxjpjpkxnfgculzip MAX_BACKUP_AGE_HOURS=26 \
    FAKE_STORED_AT="$FAKE_STORED_AT" FAKE_SOURCE_AT="$FAKE_SOURCE_AT" \
    FAKE_SOURCE_REF="${FAKE_SOURCE_REF:-dnlqxjpjpkxnfgculzip}" FAKE_SCHEMA_VERSION="${FAKE_SCHEMA_VERSION:-1}" \
    FAKE_APP_ID="${FAKE_APP_ID:-family-ops-recovery-v1}" FAKE_SLOT_ID="${FAKE_SLOT_ID:-household-durable-v1}" \
    FAKE_TABLES_TYPE="${FAKE_TABLES_TYPE:-object}" FAKE_HOUSEHOLDS="${FAKE_HOUSEHOLDS:-1}" \
    FAKE_MEMBERS="${FAKE_MEMBERS:-1}" FAKE_TASKS="${FAKE_TASKS:-1}" bash "$FRESHNESS"
}
FAKE_STORED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; FAKE_SOURCE_AT="$(timestamp_seconds_ago $((25*3600+55*60)))"; run_freshness >/dev/null
FAKE_STORED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; FAKE_SOURCE_AT="$(timestamp_seconds_ago $((26*3600+5*60)))"; expect_status 1 run_freshness
FAKE_STORED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; FAKE_SOURCE_AT="$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)"; expect_status 1 run_freshness
FAKE_STORED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; FAKE_SOURCE_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; FAKE_TASKS=0 expect_status 1 run_freshness
FAKE_TASKS=1 FAKE_APP_ID=mana-evo expect_status 1 run_freshness

grep -Fq 'name: operational-safety (backup controls)' "$ROOT/.github/workflows/operational-safety-ci.yml" || fail "protected operational-safety check name changed"
echo "PASS: right-sized CF-11 namespace/backup/identity-recovery control regressions"
