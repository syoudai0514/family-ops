# Backup / Restore Runbook

- **CF:** CF-11
- **CURRENT authority:** ADR 0014 + `docs/design/current/10_BACKUP_RECOVERY.md`
- **Legacy note:** v6 WP10's R2/age mechanics are superseded for CURRENT
  two-person operation. Do not edit the historical v6 files.

## 1. What this runbook protects

The goal is not iPhone replacement: Family Ops data already lives in Supabase.
This runbook covers loss/corruption of durable household data caused by a
Family Ops Supabase-side mistake or project-level failure.

CURRENT recovery is intentionally right-sized. It uses only existing services:

- Family Ops Supabase: `dnlqxjpjpkxnfgculzip`
- existing separate Supabase `app-save-hub`: `wdwbmvpipbdpomqulsrj`
- GitHub Actions
- existing GitHub secret `SUPABASE_ACCESS_TOKEN`

There is no current Cloudflare R2 bucket, age key, backup-only database URL, or
owner-local decryption key requirement.

## 2. Data that is recoverable

The exact allowlist is `scripts/family_ops_recovery_tables.txt`.

It covers durable household/domain state: household/member/profile references,
tasks/subtasks/recurrence/history, requests, shopping, handovers, routines,
transport templates/overrides, family events, child/school and confirmed
nursery data.

The snapshot deliberately does **not** copy:

- Auth passwords, identities, sessions, recovery/OAuth tokens;
- Google refresh tokens/credentials or provider write/sync queues;
- LINE secrets/link tokens/provider delivery queues;
- webhook/pending-action/notification queues or worker receipts;
- pg_cron / pg_net environment commands/requests;
- test/simulation rows;
- transient raw AI/image extraction/review state;
- Storage object bytes.

Only old household Auth UUID/email references are retained for operator mapping;
they are not credentials.

## 3. Daily backup operation

Workflow: `.github/workflows/backup.yml`

Normal schedule: daily 03:00 JST.

A PASS run does all of the following:

1. reads every reviewed allowlist table from Family Ops through Supabase
   Management API using the existing `SUPABASE_ACCESS_TOKEN`;
2. filters `test_context_id` rows where applicable;
3. records production migration version and non-secret Auth ownership refs;
4. writes one immutable `family-ops / household` history row into
   `app-save-hub.public.app_save_backups`;
5. updates `app-save-hub.public.app_saves` as the current copy;
6. keeps only the latest 30 Family Ops history rows;
7. reads the complete current payload back from `app-save-hub`;
8. compares full canonical JSON equality;
9. prints `RESULT: PASS` only after equality.

The workflow must never upload the household snapshot as a GitHub artifact or
print the payload in logs.

### Backup failure

A red backup run is operational failure, not a successful backup with a warning.
Do not create a new backup service/secret as an ad-hoc fix. Investigate:

- is `SUPABASE_ACCESS_TOKEN` still configured and valid;
- can it access both existing Supabase projects;
- do `app_saves` and `app_save_backups` still match the reviewed app-save-hub
  contract;
- did a new durable domain table require an explicit recovery allowlist review;
- did source schema/migration change incompatibly.

## 4. Freshness

Workflow: `.github/workflows/backup_freshness_alert.yml`

The independent check reads only latest snapshot metadata from app-save-hub.
PASS requires the payload to be structurally valid and no older than exactly
26 hours.

Do not treat a current timestamp with missing/invalid household data as fresh.

## 5. Recovery drill

Workflow: `.github/workflows/recovery-drill.yml`

The drill automatically runs after a **main-push-triggered** backup, which gives
a real proof after CF-11 implementation changes. Daily scheduled backups do not
start a disposable Supabase every day. The workflow may also be manually
dispatched.

The drill must:

1. start a disposable local Supabase stack;
2. apply repository migrations from empty;
3. fetch the latest app-save-hub Family Ops snapshot;
4. require source migration version = scratch migration version;
5. require snapshot table keys = exact reviewed allowlist;
6. create non-login placeholder `auth.users` references only for FK checking;
7. restore every non-empty allowlisted table with normal FK/check enforcement;
8. verify exact row-count equality for every allowlisted table;
9. verify household/profile/member and task/subtask linkage has no orphan;
10. stop the disposable stack even on failure;
11. print `RESULT: PASS` only at the end.

A script/test green without a real stored snapshot and real disposable restore
is not CF-11 PASS evidence.

## 6. Real incident — repaired/original project with Auth intact

Use this path when household/domain rows were accidentally deleted/corrupted but
the project/Auth users still exist.

1. Stop normal Family Ops household mutations and scheduled/provider workers.
2. Identify the last known-good Family Ops snapshot revision in app-save-hub.
3. Ensure the target schema is at the snapshot-compatible repository migration.
4. Ensure the affected household/domain tables are empty or use a separately
   reviewed incident-specific cleanup plan. Never overwrite live mixed state.
5. Run the reviewed restore tooling against the managed target only with the
   explicit safety flag:

   `ALLOW_MANAGED_RECOVERY_TARGET=1 scripts/restore_drill.sh --scratch-db-url '<target connection>'`

   Do not paste the real connection string into chat or logs.
6. Require exact row counts and zero foundational linkage orphan.
7. Re-enable provider/worker paths only after household data validation.
8. Smoke real sign-in, household load, Today/tasks and then LINE/Google paths.

## 7. Real incident — entire Family Ops project recreated

CURRENT CF-11 accepts operator-assisted reconstruction rather than preserving
old provider/Auth sessions.

1. Create a fresh Supabase project and apply Family Ops migrations from GitHub.
2. Have the household users sign in normally so new Supabase Auth identities are
   created.
3. Read the snapshot's old `{id,email}` Auth references and map the at-most-two
   old household users to the new identities.
4. Restore household/domain rows using a reviewed incident-specific user-ID
   mapping. Do not invent or guess user ownership.
5. Deploy CURRENT Edge Functions and configure CURRENT server secrets.
6. Reconnect LINE/Google; do not restore old OAuth sessions/tokens/queues.
7. Recreate the reviewed six Family Ops workers only against the new target
   using `scripts/reconfigure_recovery_workers.sql` after new target-local
   worker values are configured.
8. Smoke sign-in, household data, Today, LINE notification and routine flow.

Automating account/provider cutover beyond this is not required for current
CF-11 and must not be added solely for technical completeness.

## 8. CF-11 PASS checklist

CF-11 is PASS only when CURRENT evidence shows:

- [ ] ADR 0014 and CURRENT design/runbook are merged through protected main.
- [ ] Daily backup workflow SUCCESS on CURRENT main.
- [ ] `app-save-hub` has a current `family-ops / household` save and history.
- [ ] Complete stored payload was read back identical to the source snapshot.
- [ ] Family Ops history retention is bounded to 30 without changing ManaEvo.
- [ ] Freshness workflow SUCCESS at <=26h.
- [ ] Actual disposable recovery drill SUCCESS with exact per-table row counts.
- [ ] Provider credentials/queues/cron/test data are not in the snapshot scope.
- [ ] No R2/age/new key-management dependency exists.
- [ ] Repository release path remains protected by CF-15.

After all boxes have live evidence, update `PRODUCTION_CONNECTION_STATUS.md`
with the exact workflow run IDs and mark CF-11 PASS / Lane C COMPLETE through a
normal protected PR.

## 9. When to revisit independent/offsite DR

Reopen the stronger backup design if Family Ops becomes commercial, materially
expands its users, gains contractual recovery obligations, starts retaining
irreplaceable binary household source data, or the Product Owner no longer
accepts same-account Supabase residual risk.
