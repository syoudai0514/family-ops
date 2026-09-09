# 10. Backup / Recovery — CURRENT

- **Status:** Canonical detailed design for CF-11
- **Authority:** Requirements Baseline + ADR 0012 + ADR 0013 + ADR 0014
- **Operating scale:** current two-person household

## 1. Product outcome

CF-11 exists so a Family Ops device is not the only copy of household data and,
more importantly, so a Family Ops Supabase-side mistake or project-level data
loss does not automatically erase the household's durable operational history.

The CURRENT minimum outcome is:

> Supabase側の誤操作・障害等で家庭データを失った場合にも、現利用規模に対して
> 合理的な方法で家庭データを復旧できる。

This is not a commercial multi-region/offsite DR claim.

## 2. Authority / legacy v6 disposition

Legacy v6 WP10 selected R2 + age + owner-local key. ADR 0014 supersedes those
specific mechanics for CURRENT CF-11. `docs/design/v6/` remains unchanged as
historical design per ADR 0012/0013.

The requirements-level outcome remains technology-neutral; this document owns
the CURRENT concrete implementation.

## 3. Architecture

```text
Family Ops production Supabase
  dnlqxjpjpkxnfgculzip
        |
        | existing SUPABASE_ACCESS_TOKEN
        | Supabase Management API / HTTPS
        v
GitHub Actions backup.yml
        |
        | reviewed household-domain JSON snapshot
        v
Existing separate Supabase app-save-hub
  wdwbmvpipbdpomqulsrj
  public.app_saves         = latest Family Ops copy
  public.app_save_backups  = immutable recent history (30)
```

No new provider is introduced. There is no R2 credential, age recipient, age
private key, or backup-only DB password.

## 4. Recovery data boundary

The source of truth for included tables is
`scripts/family_ops_recovery_tables.txt`. It is an explicit allowlist, not
`select * from every schema`.

Included data is durable household/domain truth such as:

- household/profile/member ownership references;
- tasks, subtasks, recurrence, actual/history evidence;
- requests and assignment-change attempts;
- shopping and handovers;
- routine schedule/check-in/reconciliation state;
- transport weekly/override/review state;
- confirmed family event, child/school and nursery domain data;
- household preferences/terminology/categories.

Rows carrying `test_context_id` are omitted from the snapshot.

Excluded data is environment/provider/operational state:

- Auth password hashes, identities, sessions and recovery/OAuth tokens;
- private Google credentials and OAuth states;
- LINE link tokens/channel credentials and delivery/quota queues;
- notification/webhook/pending-action queues and worker receipts;
- pg_cron / pg_net requests and commands;
- Google provider cache/sync/write/mirror lifecycle state;
- transient AI/image extraction/review/raw-input state;
- test/simulation state;
- artifact handoff/evidence transport rows;
- Storage object bytes.

The snapshot contains only minimal `{id,email}` Auth references for household
members so an operator can understand old user ownership. Those references are
not authentication credentials.

## 5. Backup contract

`.github/workflows/backup.yml` runs daily at 03:00 JST, manually, and after a
protected main merge that changes CF-11 recovery implementation.

A successful run MUST:

1. authenticate with the existing `SUPABASE_ACCESS_TOKEN`;
2. read CURRENT production migration version;
3. read every allowlisted table from Family Ops production;
4. fail if an allowlisted table is missing;
5. filter `test_context_id is not null` rows where that column exists;
6. require foundational household/profile/member/task data to be non-empty;
7. validate the existing `app-save-hub` `app_saves` / `app_save_backups`
   contract instead of silently creating target schema;
8. append one `family-ops / household` history row;
9. update the matching latest `app_saves` row;
10. retain only the latest 30 Family Ops history rows without touching ManaEvo;
11. read the full latest JSONB payload back from `app-save-hub`;
12. compare the complete canonicalized payload with the source snapshot;
13. emit `RESULT: PASS` only after full equality.

The job MUST NOT upload the household snapshot as a GitHub artifact or print
its contents in logs.

## 6. Freshness contract

`.github/workflows/backup_freshness_alert.yml` independently reads only latest
snapshot metadata from `app-save-hub`.

PASS requires:

- source project ref = Family Ops production;
- snapshot schema version supported;
- tables object present;
- foundational row counts positive;
- source snapshot timestamp parseable and not materially in the future;
- exact elapsed age <= 26 hours.

The alert does not treat a fresh timestamp with an invalid/missing payload as
healthy.

## 7. Recovery drill contract

`.github/workflows/recovery-drill.yml` performs an actual recovery proof after
a main-push-triggered backup and can also be manually dispatched. Scheduled
daily backups do not launch a daily restore stack.

The workflow:

1. checks out the exact source main SHA;
2. starts a disposable local Supabase stack;
3. applies all CURRENT repository migrations from empty;
4. fetches the latest Family Ops payload from `app-save-hub`;
5. requires snapshot migration version = disposable schema migration version;
6. verifies the snapshot table key set exactly equals the reviewed allowlist;
7. creates only placeholder `auth.users` rows for old household UUID/email
   references, with Auth triggers suppressed;
8. inserts household/domain rows in dependency order with normal FK/check
   enforcement active;
9. compares exact per-table restored row counts to the snapshot manifest;
10. checks foundational household/member/task/subtask identity links;
11. emits `RESULT: PASS` only if all checks succeed;
12. always stops the disposable stack.

The drill does not contact LINE or Google and cannot replay old cron/net queue
state because those rows are not in the snapshot.

## 8. Real incident recovery

### 8.1 Same/repaired project, Auth still present

For accidental household-table deletion/corruption where Supabase Auth survived:

1. pause household mutations;
2. identify a known-good `app_save_backups` revision;
3. apply repository migrations/schema as needed;
4. restore the selected household payload using the reviewed recovery tooling;
5. verify row counts and household/task linkage;
6. verify real sign-in and Family Ops reads;
7. resume mutations.

### 8.2 Recreated Supabase project

For complete project recreation:

1. create/restore Family Ops schema from GitHub migrations;
2. re-establish users through normal Supabase Auth sign-in;
3. use snapshot Auth UUID/email references to map the at-most-two household
   users to the new Auth identities;
4. restore household/domain data with reviewed user mapping;
5. reconfigure Edge secrets/functions;
6. reconnect LINE/Google rather than restoring old provider sessions;
7. recreate reviewed Family Ops workers only against the new target;
8. smoke sign-in, Today/household load, LINE and scheduled operations before
   declaring incident recovery complete.

Automating full provider/account cutover is outside CURRENT CF-11 minimum and
must not be added merely to make the drill more elaborate.

## 9. Accepted residual risk / escalation triggers

Both Family Ops and `app-save-hub` use Supabase under the same existing account.
This protects against Family Ops project/database mistakes and project-level
loss, not a whole-account or Supabase-wide catastrophic loss.

Re-evaluate independent encrypted/offsite DR if any of these become true:

- commercialization or materially larger user base;
- meaningful contractual/SLA recovery obligations;
- irreplaceable binary household source material becomes durable product data;
- account/provider-level loss becomes an unacceptable Product Owner risk.

## 10. CF-11 acceptance gate

CF-11 = PASS only with CURRENT operational evidence for all gates:

| Gate | Required evidence |
| --- | --- |
| Authority | ADR 0014 Accepted; CURRENT design/runbook agree; v6 conflict explicitly superseded |
| Backup | Main `backup.yml` SUCCESS using existing Supabase token + separate app-save-hub |
| Integrity | Complete snapshot read-back equals source; foundational counts non-zero |
| Retention | Family Ops history bounded to latest 30; ManaEvo rows untouched |
| Freshness | Independent check SUCCESS and exact age <=26h |
| Recovery | Disposable Supabase restore workflow SUCCESS with typed rows + exact per-table counts |
| Isolation | No R2/age/private key; no provider credentials/queues/cron/test rows in payload |
| Release | All repository changes merged through CF-15 protected PR + five required checks |

Only then may `PRODUCTION_CONNECTION_STATUS.md` record CF-11 PASS and Lane C
COMPLETE.
