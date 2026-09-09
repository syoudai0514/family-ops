# 10. Backup / Recovery — CF-11 right-size proposal

- **Status:** Product Owner approved / pending canonical merge
- **Authority when merged:** Requirements Baseline + ADR 0012 + ADR 0013 + ADR 0014
- **Operating scale:** current two-person household

This branch document is not canonical until the protected PR is merged to
`main`. CURRENT main authority remains in force until then.

## 1. Product outcome

CF-11 exists so a Family Ops Supabase-side mistake or project-level data loss
does not erase the household's durable data or make the household permanently
unusable.

Minimum outcome:

> Supabase側の誤操作・障害等で家庭データを失った場合にも、現利用規模に対して
> 合理的な方法で復旧し、家族が再ログインして元の家庭データへ到達できる。

This is not a commercial multi-region/offsite DR claim.

## 2. Authority / legacy v6 disposition

Legacy v6 WP10 selected R2 + age + owner-local key. Product Owner approved ADR
0014 to supersede those mechanics. Under ADR 0012, that supersession takes
canonical effect only after ADR 0014 reaches protected `main`.
`docs/design/v6/` remains unchanged.

## 3. Architecture and app-save-hub separation

```text
Family Ops production Supabase (read only during backup)
  dnlqxjpjpkxnfgculzip
        |
        | existing SUPABASE_ACCESS_TOKEN / Management API
        v
GitHub Actions
        |
        v
Existing separate app-save-hub Supabase
  wdwbmvpipbdpomqulsrj

  ManaEvo:    owner / mana-evo / main
  Family Ops: owner / family-ops-recovery-v1 / household-durable-v1
```

The app-save-hub schema is shared, but Family Ops operations are isolated by an
exact three-part key: `user_id + app_id + slot_id`.

Family Ops MUST use:

- `app_id = family-ops-recovery-v1`
- `slot_id = household-durable-v1`
- the single reviewed app-save-hub owner `user_id`

Revision lookup, current-save upsert, generation pruning, read-back, restore
selection and freshness selection MUST all include that exact tuple. Family Ops
code MUST NOT delete/prune by `app_id` or `slot_id` without the owner predicate.
Normal app-save-hub RLS remains enabled and owner-scoped by `auth.uid() = user_id`.
The Management API token is an operator transport and does not weaken the
normal app RLS boundary.

No new provider, R2 credential, age key or backup-only DB password is added.

## 4. Recovery data boundary

`scripts/family_ops_recovery_tables.txt` is the explicit allowlist.
Included data is durable household/domain truth: household/profile/member,
tasks/subtasks/recurrence/history, requests, shopping, handovers, routine,
transport, family events, child/school/nursery confirmed data and household
preferences.

Rows carrying non-null `test_context_id` are excluded.

Explicitly excluded:

- Auth password hashes, identities, sessions, recovery/OAuth tokens;
- private Google/LINE credentials and OAuth/link state;
- delivery/webhook/pending/worker queues and receipts;
- cron/pg_net state;
- Google provider cache/sync/write/mirror lifecycle state;
- transient AI/image extraction/raw state;
- test/simulation state;
- artifact handoff rows and Storage object bytes.

The snapshot carries only `{old auth UUID, lower-cased email}` for current
household members. Email is recovery matching data, not an authentication
credential.

## 5. Backup contract

`.github/workflows/backup.yml` runs daily at 03:00 JST and on relevant protected
main changes. The PR recovery evidence workflow can also create a real snapshot
before merge.

PASS requires:

1. existing `SUPABASE_ACCESS_TOKEN` only;
2. read CURRENT production migration version and every allowlisted table;
3. fail on missing allowlist table;
4. exclude test-context rows;
5. require non-empty household/profile/member/task backbone;
6. validate app-save-hub schema, RLS, single trusted owner and namespace owner;
7. append exactly within the reserved owner/app/slot tuple;
8. upsert latest copy using the same tuple;
9. prune only that tuple to <=30 generations;
10. retrieve the complete stored payload through the separate project;
11. canonical JSON equality with source payload;
12. no household payload in Actions artifacts/logs.

## 6. Freshness

Independent freshness selects only the reserved owner/app/slot tuple. PASS
requires correct source project and recovery namespace, valid structure,
positive foundational counts and exact snapshot age <=26h.

## 7. Usable identity recovery / identity rebinding

A complete Supabase project loss changes Auth UUIDs when users are recreated or
reinvited. Preserving old production Auth rows is intentionally not required.

Safe recovery is:

1. deploy CURRENT Family Ops schema/migrations to a new Supabase target;
2. for every identity reference in the snapshot, recreate/reinvite the same
   verified email through normal Supabase Auth;
3. obtain the new Auth UUID after successful authentication;
4. build an exact `old_uuid -> new_uuid` mapping;
5. discover user-reference columns from the CURRENT target schema's FK catalog,
   not by guessed column names;
6. rewrite only FK positions that reference `auth.users.id` or
   `household_members.user_id`;
7. typed-insert the household snapshot with normal FK/check constraints active;
8. verify every source field survives the restore after UUID rebinding; target-
   only fields may exist, but source fields may not be silently discarded;
9. verify no old production UUID remains in those identity-FK positions;
10. sign in as every recovered identity and use its JWT against normal public
    PostgREST/RLS reads;
11. require access to that user's profile, household membership, household and
    at least one restored household task.

Supabase migration history IDs are recorded as diagnostic evidence, not treated
as a schema-compatibility identity. The same reviewed migration can receive a
different remote timestamp depending on deployment path. Recovery compatibility
is therefore proven directly by required-table presence, typed insertion under
CURRENT constraints, exact row counts, exact preservation of all source fields,
and authenticated RLS use.

The disposable drill creates one-time local Auth users with the same snapshot
emails and random temporary passwords, signs in via GoTrue, then performs the
same UUID rebinding and RLS access checks. Passwords/tokens are temporary and
are never copied from production or logged/artifacted.

CURRENT production evidence may contain fewer than two registered Auth members;
the implementation loops over every identity represented in the snapshot, so
the same mechanism covers the second spouse once registered. Evidence must
state the actual tested identity count rather than claiming two if only one is
present.

## 8. Recovery evidence workflow

For same-repository PR changes to recovery controls,
`.github/workflows/recovery-drill.yml` performs before merge:

1. actual read-only snapshot of Family Ops production into the isolated
   app-save-hub namespace;
2. complete read-back equality (inside snapshot script);
3. freshness check;
4. disposable real Supabase CLI stack;
5. migrations from empty;
6. creation of NEW Auth users + real GoTrue sign-in for every snapshot identity;
7. old→new UUID rebinding derived from actual target FKs;
8. typed restore under normal constraints;
9. exact per-table row counts, all source-field content equality and graph/orphan
   checks;
10. authenticated PostgREST/RLS access to profile/membership/household/task;
11. cleanup of temporary sessions and disposable stack.

Family Ops production is never mutated by this workflow. The only persistent
write is a new Family Ops generation in app-save-hub.

## 9. Real incident recovery

### 9.1 Household DB damage while Auth survives

Pause household mutations, choose a known-good generation, restore durable rows,
verify linkage and real authenticated household reads, then resume.

### 9.2 Complete project recreation

1. create new Supabase project and apply repository migrations;
2. configure Auth provider/domain settings;
3. have each spouse sign in again or securely recreate/reinvite their verified
   email account;
4. confirm each new Auth identity matches exactly one snapshot email reference;
5. run old→new UUID rebinding + household restore;
6. verify each spouse's normal authenticated profile/membership/household/task
   reads before opening Family Ops for use;
7. reconfigure Edge secrets/functions and reconnect LINE/Google;
8. recreate workers only against the new project;
9. perform normal Family Ops smoke checks.

Automating provider cutover is outside this right-sized CF-11 minimum.

## 10. Accepted residual risk / escalation

Family Ops and app-save-hub remain Supabase projects under the existing account.
The design protects primarily against Family Ops project/database/operator loss,
not whole-account/provider catastrophe. Revisit independent offsite/encrypted DR
if commercialization, materially larger usage, SLA obligations, irreplaceable
binary data, or Product Owner risk posture changes.

## 11. CF-11 acceptance gate

| Gate | Required evidence |
| --- | --- |
| Governance | ADR 0014 is merged to protected main before it is called Accepted/canonical |
| Namespace | owner + `family-ops-recovery-v1` + `household-durable-v1`; ManaEvo/other tuples untouched |
| Backup | actual snapshot stored in separate app-save-hub project |
| Integrity | complete read-back equals source; <=30 Family Ops generations |
| Freshness | independent check PASS, exact age <=26h |
| Restore | disposable Supabase typed restore + exact counts + all source-field content equality + no linkage orphans |
| Identity | every snapshot identity gets a NEW Auth UUID, signs in, is rebound, and reads restored profile/membership/household/task through normal RLS |
| Isolation | no R2/age/private key and no provider credentials/queues/cron/test rows in payload |
| Release | five protected checks and merge through CF-15 main ruleset |

Only after all gates, including canonical merge and post-merge operational
currency, may CF-11 = PASS and Lane C = COMPLETE.
