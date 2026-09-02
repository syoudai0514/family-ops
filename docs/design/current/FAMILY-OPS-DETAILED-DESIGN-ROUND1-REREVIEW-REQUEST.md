# Family Ops Detailed Design — Round 1 NO-GO Remediation Re-Review

## 0. Mode

**INDEPENDENT RE-REVIEW / NO IMPLEMENTATION**

Repository:

`syoudai0514/family-ops`

Target:

- PR `#41`
- **fresh-read the actual current PR head; do not reuse the old reviewed head `6e63eb1661869c7ad549139e91bc480994d55f0b`**
- fresh-read CURRENT `main`

Do not modify code, docs, migration, Supabase, LINE, Google, Vercel, production data, commit, or PR.

Use the full original review instruction as the base rubric:

`docs/design/current/FAMILY-OPS-DETAILED-DESIGN-INDEPENDENT-REVIEW-REQUEST.md`

Then apply this file as the mandatory Round 1 remediation gate.

## 1. Round 1 result to re-check

Previous verdict:

- `NO-GO`
- `BLOCKER 0`
- `HIGH 3`
- `MEDIUM 3`
- `LOW 0`

Requirements Final-GO MEDIUM carryovers were already `3/3 PASS` and must not regress.

Do not assume the PR description is accurate. Verify actual Git blobs/docs/code.

## 2. HIGH-1 — Task `待ち` current truth

Previous problem:

Canonical Requirements requires formal waiting behavior, but the detailed design had only five operational task statuses and no waiting dimension.

Verify the current PR head now closes this across architecture, data, commands, DailyBrief/UX, and rollout.

Required properties:

- `待ち` is **not** added as an unnecessary sixth task status.
- canonical current truth exists as an orthogonal attention dimension such as `attention_state=active|waiting`.
- waiting note/state memo is representable.
- `next_check_at` is representable and optional.
- original hard `due_at` remains intact.
- waiting suppresses ordinary incomplete/nag behavior.
- next-check arrival resurfaces the task as a check target without auto-resuming it.
- hard-deadline risk can surface while still waiting.
- set/update/resume commands are revision/idempotency safe.
- terminal completion/skipped/cancelled does not leave an active waiting truth.
- event preparation uses the same Task waiting semantics rather than a second task-state model.
- DailyBrief/PWA/LINE acceptance scenario is explicit.

Also verify waiting is excluded from normal bulk reconciliation unless explicitly resumed.

If an implementer still has to invent persistence or Today behavior, this item is not PASS.

## 3. HIGH-2 — Simulated actor persistence identity

Previous problem:

The design forbade fake auth/member users, but assignee/claimant/performer/recorder/request/confirmation tables still assumed real `user_id`, making simulated mama impossible to persist without contaminating real identity.

Verify one common actor identity model now exists and is used consistently. Read `08_ACTORREF_LEGACY_IDENTITY_COMPATIBILITY.md` together with 01/02/03/06/07 rather than assuming CURRENT real-user-only FKs remain unchanged.

Required properties:

- one canonical domain actor reference model for:
  - real household user
  - simulated member
  - system
- simulated member has test-context + role identity and no fake auth/member row.
- operator real user ID is never substituted for simulated mama/papa.
- the same actor-reference principle reaches at least:
  - planned assignee
  - anyone claimant
  - actual performer
  - recorder
  - Request requester/recipient/creator
  - consultation confirmation
  - reconciliation actor
  - audit actor
- production-scoped aggregate cannot reference simulated actor.
- test-scoped aggregate can reference simulated actor only from the same household/test context.
- legacy real-user columns, when temporarily retained, are compatibility mirrors only and stay null/not fabricated for simulated actors.
- CURRENT real-user-only `NOT NULL`/PK/FK shapes that would prevent a simulated row have an explicit compatibility evolution; the design must not merely say “use ActorRef” while leaving an impossible legacy constraint.
- Request legacy requester/recipient, `task_events.actor_id`, and handover/ack identity have a concrete migration/compatibility story.
- mutation/idempotency identity distinguishes operator from simulated actor.
- real spouse onboarding never rewrites simulated actor into real spouse.

Mandatory identity E2E:

real papa sends request to simulated mama → simulated mama checks/accepts → simulated mama becomes task assignee → claims/performs/records → consultation can persist both real and simulated confirmations → audit/history still displays simulated mama, not papa.

If that E2E still needs a fake user or operator-ID substitution, this item is FAIL/HIGH.

## 4. HIGH-3 — Semantic cutover rollback contract

Previous problem:

The design claimed rollback by feature/read path after new semantic writes, even though legacy UI/schema cannot represent checking/consulting/anyone claim/multiple performer/mostly-done evidence.

Verify phase-specific rollback is now realistic.

Required properties:

- pre-new-write additive schema/backfill can safely revert runtime to old behavior.
- old public endpoints route through new command adapters once a domain is cut over; old semantic writes cannot reappear freely.
- explicit **point of no return** exists when the first new-only semantic state is generated.
- after that point, legacy current-truth read/write rollback is forbidden.
- incident feature-off means:
  - pause new mutations where necessary, and
  - render canonical new truth through compatibility/degraded projection, or forward-fix.
- feature flag is not treated as a truth rollback switch.
- work packages/release gates record the rollback class/P1 state.
- a concrete incident scenario exists: a Request is `checking`, then a runtime defect occurs; the system must not restore the legacy `引き受ける / 断る` UI as current truth.

If the rollout still promises semantic rollback that loses new state meaning, this item remains HIGH.

## 5. MEDIUM-1 — `outcome_reason` current snapshot

Previous problem:

State design distinguished `今回は不要` and `できなかった`, but Data Model did not hold the reason as current truth.

Verify:

- new `skipped` writes carry current `outcome_reason`.
- at least `not_needed_this_occurrence`, `could_not_do`, `expired_occurrence` are distinguishable.
- current read/History/analytics need not replay audit events to know the reason.
- legacy skipped reason is not guessed; explicit legacy-unknown treatment is allowed.
- E2E acceptance covers `今回は不要` vs `できなかった`.

## 6. MEDIUM-2 — Legacy Request mismatch audit

Previous problem:

Backfill checked missing links, but not broader historical inconsistency before making linked Task the new execution truth.

Verify read-only pre-cutover reconciliation now covers:

- missing linked task
- duplicate/invalid link
- Request terminal state vs linked Task state mismatch
- deterministically detectable timestamp inconsistency

Rules:

- no guessed task creation/completion/repair.
- anomalous rows are reported/quarantined/classified explicitly.
- unresolved anomaly cannot silently cross semantic cutover.

## 7. MEDIUM-3 — Test-mode dependency ordering

Previous problem:

One-user test was scheduled before the work package that implemented its sandbox.

Verify:

- test ActorRef/execution-context/hard side-effect guard is a prerequisite package before actual-household one-user testing.
- domain commands can be exercised under that sandbox.
- later test-mode package is UX/transition polish, not the safety foundation.
- rollout order matches the dependency.

## 8. Regression check — Requirements Final-GO MEDIUM 3

Re-evaluate and report `PASS / PARTIAL / FAIL` for all three. They were previously `PASS` and must remain so.

1. `大体やった` + carryover UX noise
2. duplicate-sensitive neutral completion notification
3. one-user synthetic delivery vs production delivery boundary

A regression to HIGH/BLOCKER means no GO.

## 9. Cross-document consistency check

Fresh-read at minimum:

- canonical Requirements Baseline
- ADR 0012
- proposed ADR 0013
- `docs/design/current/README.md`
- design 01–08
- original independent review request
- this re-review request
- relevant CURRENT main schema/types/Requests/Today/LINE/Google implementation

Specifically search for stale contradictions such as:

- simulated actor still represented only as `user_id`
- existing real-user-only NOT NULL/PK/FK left impossible for simulated test persistence
- `rollback by old read path` after semantic P1
- waiting absent from Task/DailyBrief
- `outcome_reason` only in audit prose
- actual-household test before sandbox foundation

If an old line is merely a clearly marked legacy compatibility field, do not flag it just for existing. Flag it if it can still be mistaken for canonical truth or makes the new canonical path physically impossible.

## 10. Required output

Start with one of:

- `GO`
- `GO WITH CONDITIONS`
- `NO-GO`

Then report:

- `BLOCKER / HIGH / MEDIUM / LOW` counts
- six Round 1 findings individually as `PASS / PARTIAL / FAIL`
- three Requirements Final-GO MEDIUM items as `PASS / PARTIAL / FAIL`
- any new findings using the original review format:
  - problem
  - concrete household/system scenario
  - why it matters
  - recommended fix
- updated truth-ownership / migration-safety / implementation-leverage observations only where materially changed
- final verdict on whether PR #41 may merge and implementation planning may begin

## 11. Gate

- If any `BLOCKER` or `HIGH` remains: **do not return GO**.
- `MEDIUM` may be carried to implementation acceptance only if it does not force implementers to invent current truth, consent identity, migration cutover, or safety-critical behavior.
- Do not require exact SQL column types, Flex JSON, OCR model selection, or other safely deferrable implementation detail.

The key question is:

**Can an implementation team now build migration + command + DailyBrief + test sandbox without inventing product/domain truth that the canonical Requirements already decided?**