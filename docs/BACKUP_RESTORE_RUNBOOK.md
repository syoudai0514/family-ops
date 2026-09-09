# Backup / Restore Runbook

- **CF:** CF-11
- **Proposal status:** Product Owner approved / pending canonical merge
- **Authority after merge:** ADR 0014 + `docs/design/current/10_BACKUP_RECOVERY.md`
- **Legacy note:** v6 WP10 R2/age mechanics are superseded only after the protected merge that makes ADR 0014 canonical.

## 1. Recovery objective

Protect durable household data from Family Ops Supabase-side mistake/project-level loss and restore **actual family usability**, not merely database rows.

Existing services only:

- Family Ops Supabase `dnlqxjpjpkxnfgculzip`
- separate existing `app-save-hub` `wdwbmvpipbdpomqulsrj`
- GitHub Actions
- existing `SUPABASE_ACCESS_TOKEN`

No R2, age key, backup-only DB URL or new backup provider is required by the right-sized proposal.

## 2. app-save-hub isolation

ManaEvo and Family Ops share the generic save tables but not a namespace.

- ManaEvo CURRENT tuple: `owner / mana-evo / main`
- Family Ops reserved tuple: `owner / family-ops-recovery-v1 / household-durable-v1`

Every Family Ops revision lookup, insert/upsert, generation prune, read-back,
freshness and restore selection MUST include the exact owner `user_id`, app_id
and slot_id. Never prune/delete by app/slot without owner scope.

`app_saves`/`app_save_backups` RLS remains enabled and user-scoped. The backup
script preflights the single trusted app-save-hub owner, RLS and namespace owner
before writing. This is operational namespace isolation inside one personal
save service, not a claim of adversarial tenant isolation between the owner's
own apps.

## 3. Recoverable data

Exact allowlist: `scripts/family_ops_recovery_tables.txt`.

Included: durable household/member/profile, task/subtask/recurrence/history,
request, shopping, handover, routine, transport, family-event, child/school,
confirmed nursery and household-setting data.

Excluded:

- Auth passwords/hashes, identities, sessions, recovery/OAuth tokens;
- Google/LINE credentials and provider queues;
- webhook/pending/notification/worker queues and receipts;
- cron/pg_net state;
- provider caches/write/sync/mirror operational state;
- test/simulation and transient AI/image/raw state;
- artifact-handoff rows and Storage object bytes.

Only old household Auth UUID + lower-cased email are retained for safe identity
rebinding. They are not credentials.

## 4. Actual backup

Workflow: `.github/workflows/backup.yml`; normal schedule 03:00 JST.

A PASS backup:

1. reads production through Management API with existing token;
2. reads migration version and every allowlisted table;
3. excludes non-null test contexts;
4. validates foundational household/profile/member/task data;
5. validates app-save-hub schema/RLS/single owner/namespace;
6. writes one generation to the exact Family Ops owner/app/slot tuple;
7. updates only that tuple's current save;
8. prunes only that tuple to latest 30;
9. reads complete payload back from app-save-hub;
10. canonical JSON compares equal to source;
11. prints `RESULT: PASS` only after equality.

Never upload household payload or recovery sessions as Actions artifacts or log contents.

## 5. Freshness

Workflow: `.github/workflows/backup_freshness_alert.yml`.

PASS requires the reserved tuple, correct source and namespace, structurally
valid household payload, positive foundational counts and exact age <=26h.

## 6. Pre-merge recovery evidence

For a same-repository PR changing CF-11 controls,
`.github/workflows/recovery-drill.yml` performs the full proof before merge:

1. **Actual backup**: read production and write a real isolated app-save-hub generation.
2. **Read-back equality**: included in snapshot script.
3. **Freshness PASS**.
4. Start a disposable real Supabase CLI stack.
5. Apply repository migrations from empty.
6. For every snapshot Auth reference, create a **NEW** confirmed disposable Auth
   user with the same email and a random temporary password.
7. Sign in each new user through GoTrue; no production password/session is used.
8. Build old UUID → new UUID mapping.
9. Discover identity columns from target FK catalog (`auth.users.id` or
   `household_members.user_id` parents), never by guessed names.
10. Rewrite only those FK positions and typed-restore every allowlisted table
    with normal constraints active.
11. Require exact per-table counts, exact preservation of every source field
    after UUID rebinding, zero identity/task linkage orphans and no old
    production UUID remaining in identity-FK positions.
12. Use each signed-in user's JWT through normal PostgREST/RLS to read its
    profile, household membership, household and at least one restored task.
13. Remove temporary session material and stop disposable stack even on failure.

Do not fail recovery merely because Supabase migration-history timestamp IDs
differ between source and rebuilt target. The same reviewed migration may have
a different remote ID depending on deployment path. Both histories must exist,
but compatibility is proven directly by required-table presence, typed restore,
constraints, exact row counts, all source-field content equality and the final
authenticated RLS-use proof.

A green unit test or table-count-only restore is not CF-11 proof.

## 7. Complete project recreation procedure

If the original Family Ops project is lost:

1. Create new Supabase project and apply reviewed Family Ops migrations.
2. Configure the approved Auth provider/domain settings.
3. Have each spouse sign in again, or securely create/reinvite the same verified
   email identity. Do not restore old passwords/sessions.
4. Match each new authenticated email to exactly one snapshot Auth reference.
   Ambiguous/missing identity blocks recovery; never guess ownership.
5. Run the same schema-derived old→new UUID rebinding before household restore.
6. Restore durable household data under normal constraints and require exact
   preservation of all source fields represented in the snapshot.
7. **Before reopening Family Ops**, sign in as each recovered household user and
   confirm normal authenticated access to profile, membership, household and
   tasks. This is the minimum "family can resume use" gate.
8. Configure CURRENT Edge secrets/functions.
9. Reconnect LINE/Google; do not import old OAuth sessions/tokens/queues.
10. Recreate reviewed workers only against the new target.
11. Smoke Today/household use and then LINE/Google operational paths.

Provider/account cutover automation beyond this is outside current right-sized CF-11.

### Original/repaired project with Auth intact

If Auth survives, preserve the existing Auth IDs and use an incident-specific
restore plan; do not create replacement users unnecessarily. Pause mutations,
select a known-good generation, restore only into a reviewed clean/isolated
state, then prove real authenticated household access before reopening.

## 8. CF-11 PASS checklist

CF-11 remains FAIL until every item has CURRENT evidence:

- [ ] ADR 0014 reached protected main and therefore became Accepted/canonical.
- [ ] Required five protected PR checks passed on the exact merge head.
- [ ] app-save-hub isolation verified: exact owner + `family-ops-recovery-v1` + `household-durable-v1`; ManaEvo/other tuples untouched.
- [ ] Actual Family Ops backup stored in app-save-hub.
- [ ] Full payload read-back equals source.
- [ ] Family Ops generation count <=30 with tuple-scoped pruning.
- [ ] Freshness PASS <=26h.
- [ ] Actual disposable Supabase restore PASS with constraints + exact counts + all source-field content equality.
- [ ] NEW Auth identity sign-in succeeds for every identity represented in the snapshot.
- [ ] Old→new UUID rebind leaves no identity-FK orphan/stale old UUID.
- [ ] Every recovered signed-in identity reads profile/membership/household/task through normal RLS.
- [ ] Provider credentials/queues/cron/test data absent from recovery scope.
- [ ] No R2/age/new key-management dependency.

Only then may CF-11 = PASS / Lane C = COMPLETE. Record exact workflow run IDs and tested identity count; do not claim two identities if CURRENT production contains only one registered member.

## 9. When to revisit stronger DR

Reopen independent encrypted/offsite DR if commercialization, materially larger
usage, contractual recovery requirements, irreplaceable durable binaries, or
Product Owner risk posture changes.
