# 07. Acceptance, Rollout, and Implementation Work Packages

## 1. Purpose

本書は、詳細設計を「読むだけの設計書」で終わらせず、実装時に何を順番に作り、どの状態でproductionへ進めてよいかを定義する。

このPRでは実装しない。

## 2. Detailed-design exit criteria

独立レビューで少なくとも以下を満たした時のみ実装開始可能。

- BLOCKER 0
- HIGH 0
- Requirements Baselineとの矛盾なし
- ADR 0012/0013のnormative scopeが明確
- Request / task / actual / assignment / source candidateのtruth ownershipが1つに閉じる
- migration strategyが既存production dataを破壊しない
- one-user testのside-effect boundaryが実装可能
- concurrency/idempotencyのuser-visible resultが定義済み
- three Final-GO MEDIUM carryoversがacceptance criteriaに組み込まれている

MEDIUM以下は実装work packageのacceptanceへ明示的にcarryできる場合のみGO可。

## 3. Implementation principles

- no direct main push
- no production data reset/delete
- existing migration rewrite禁止
- pending/new migrationのみtimestamp順
- Edge Function auth matrixを更新してから新function deploy
- feature/cutoverはreversible
- one domain aggregateをold/new双方が自由に書くdual-write期間を作らない
- runtime behaviorがRequirements Baselineを変更する場合、codeより先/同PRでBaseline更新+review

## 4. Work package order

### WP-DD1 — Additive domain schema foundation

Scope:

- task instance assignment mode/source/claim/revision
- task definition expectation/carryover/duplicate sensitivity
- actual participants
- reconciliation sessions/items
- request attempts/confirmations
- family events/external links
- change candidates
- family children/school contexts
- source document/extraction/facts/rules
- test simulation context

No UX cutover.

Acceptance:

- migrations apply cleanly to current schema
- no destructive column drop
- RLS/FK/check/index reviewed
- existing app still runs against old read/write path
- migration rollback plan is forward-fix/feature-off, not reset

### WP-DD2 — Backfill and compatibility adapters

Scope:

- current task assignment -> new assignment snapshot
- actual_completed_by_id -> participant rows
- request rows -> request attempt representation
- handover defaults
- current task default policy snapshots

Acceptance:

- idempotent re-run
- row counts/reconciliation report
- no guessed anyone assignment
- no guessed performer
- completed request lacking linked task flagged, not fabricated
- backfill can be audited per household

### WP-DD3 — Transaction command layer + concurrency

Scope:

- task complete/correct
- assignment change
- claim/release/takeover
- group reconciliation
- request attempt transitions
- candidate resolution
- info ack/update

Acceptance:

- operation receipt replay
- expected revision conflict
- terminal attempt no reopen
- no performer overwrite
- task + audit + notification intent atomic
- LINE/PWA call same transaction contract

### WP-DD4 — Request / assignment UX cutover

Scope:

- new request composer/attempt read model
- `やる / 難しい / その他`
- checking/consulting
- reply deadline expiry
- accepted execution via linked ToDo
- accepted change/cancel negotiation
- oral already-agreed `[違う]`

Acceptance scenarios:

1. pending -> accept -> one linked task
2. checking -> deadline -> expired -> old accept blocked
3. consulting one confirm -> no assignment change
4. both same revision confirm -> assignment/task changes
5. terms edit invalidates old confirm
6. accepted request task rescheduled -> request agreement remains, execution shows task state
7. accepted cancel proposal not applied until recipient confirms

### WP-DD5 — Actual/reconciliation + History semantics

Scope:

- multiple performers
- all_done/mostly_done/individual
- carryover result certainty
- support analytics derived
- correction history

Acceptance:

- `大体やった` child status unchanged
- occurrence_end unknown closes without failure metric
- until_done appears as weak `結果未確認`
- Final-GO MEDIUM-1 compact follow-up only when meaningful
- household completion count remains one with joint performers
- assignment change before completion not counted as support

### WP-DD6 — Shared Daily Brief + LINE/PWA channel convergence

Scope:

- server DailyBrief read model
- PWA Today cutover
- LINE `今日`
- morning 06:30 / weekend holiday 09:00
- evening 20:30
- partner summary
- deep links

Acceptance:

- same underlying task/request state in LINE/PWA
- no frontend-only assignment/calendar computation
- evening does not replay completed morning details
- PWA mutation no scroll reset/full reload
- stale deep link displays current state

### WP-DD7 — Notification policy and duplicate-sensitive safety

Scope:

- intent metadata/policy engine
- immediate vs digest
- neutral duplicate-sensitive completion
- stale intent suppression
- bundling

Acceptance:

- normal partner task completion no praise push
- medication completion informs at-risk other adult with neutral `対応済み`
- transport/purchase/submission category can be configured duplicate-sensitive
- stale reminder not delivered after state resolved
- LINE quota existing protections unchanged
- Final-GO MEDIUM-2 explicitly PASS

### WP-DD8 — Family Event + Google Authority layer

Scope:

- Family Ops event aggregate
- external links
- field authority
- change candidates
- Google inbound reconciliation
- deletion/change/duplicate flows
- prep reschedule candidates

Acceptance:

- protected app event changed in Google -> candidate, no auto overwrite
- external-follow event auto-updates safe field
- local+external concurrent change -> conflict diff
- Google delete does not erase completed prep/history
- duplicate candidate links existing Google event without duplicate create
- existing sync token/watch/write idempotency behavior preserved

### WP-DD9 — Nursery/Codmon image intake

Scope:

- private storage
- intake processing
- child/school recognition
- explicit fact/inference separation
- review UI
- monthly/recurrence/update/URL handling
- raw delete

Acceptance:

- マサキ/すだち and ウタノ/ゆき never cross-school merge
- unrelated child info not durable structured entity
- source fact visibly distinct from AI suggestion
- confirmed preparation rule is school-context scoped
- raw delete leaves confirmed family data
- QR/URL safe handling
- updated notice creates candidate/history, not silent overwrite

### WP-DD10 — One-user test mode

Scope:

- test context
- simulated actor domain command
- synthetic operator delivery
- production side-effect guard
- real spouse transition

Acceptance:

- domain state machine same as production
- synthetic LINE reaches operator with `🧪`
- no production outbox
- no Google write
- no real spouse consent
- production analytics default excludes test
- real spouse join does not inherit simulated agreement
- Final-GO MEDIUM-3 explicitly PASS

### WP-DD11 — Production migration/cutover audit

Scope:

- feature gates
- old endpoint adapters
- compatibility deprecation
- production audit
- monitoring/runbook

Acceptance:

- no old/new divergent mutation route
- current production rows reconcile to new reads
- no orphan accepted requests
- no completed task participant loss
- notification duplication audit clean
- rollback by feature gate/read path possible

## 5. Feature gate strategy

Prefer capabilities rather than one giant `vNext` boolean.

Potential gates:

- `request_negotiation_v2`
- `actual_reconciliation_v2`
- `daily_brief_v2`
- `family_event_authority_v1`
- `nursery_intake_v1`
- `one_user_simulation_v1`

Rules:

- gate evaluated server-side per household
- frontend uses capability read, not hard-coded environment assumption
- related write/read pair cut over together
- do not enable new write while old UI still reads incompatible truth

## 6. Rollout order

Recommended production rollout:

1. schema/backfill only, feature off
2. domain commands/tests
3. internal one-user test on actual household with external side effects sandboxed
4. requests/actual semantics
5. DailyBrief/PWA Today
6. scheduled LINE consolidation
7. duplicate-sensitive notifications
8. event/Google Authority
9. nursery intake
10. real spouse onboarding only after test-mode acceptance

Google/event layer may be developed in parallel after domain primitives but production cutover should occur after current task/request truth is stable.

## 7. Production safety gates

Before each migration/deploy:

- current main SHA recorded
- production migration history read
- target migration pending status confirmed
- production schema preconditions queried
- no `db reset`
- no applied migration re-run
- backup freshness checked for schema-affecting work

After:

- migration history matches expected
- schema constraints exist
- Edge functions deployed only if migration compatible
- cron/outbox health
- PWA production smoke
- LINE test for changed path
- Google sync audit if changed

## 8. Data reconciliation reports

Implementation should produce read-only audit queries/scripts for:

### Tasks

- completed task count vs participant backfill
- participant missing legacy cases
- invalid assignment mode/assignee combinations
- anyone with claimant on terminal task

### Requests

- logical request count
- active attempts >1 violation
- accepted request without linked task
- legacy completed vs linked task mismatch

### Recurrence

- overlapping active rules
- future `assignment_source=rule` vs protected count

### Test

- test_context row in production outbox/Google operations = must be zero

### Sources

- raw_deleted source with live storage object = cleanup lag
- cross-household source references = zero

## 9. Test pyramid

### SQL/domain unit tests

- state constraints
- RPC transaction semantics
- RLS
- idempotency
- revision conflicts

### Edge integration tests

- JWT actor binding
- error envelopes
- test side-effect guard
- outbox intent creation

### PWA component/integration

- request actions
- Today sections
- reconciliation
- deep-link state restoration

### LINE flow tests

- webhook dedup
- postback stale handling
- Flex/quick replies
- synthetic test delivery

### Google fixtures

Retain existing provider fixtures + Authority conflict cases.

### Image intake fixtures

- two schools
- multi-page notice
- crowded schedule
- correction notice
- QR/URL
- other-child text

## 10. Mandatory end-to-end scenario suite

### Scenario A — Normal weekday

- 06:30 brief
- morning bulk complete
- daytime share
- 20:30 evening
- all done

Expected: minimal operations, no duplicate self notifications.

### Scenario B — Request checking expiry

- pickup change request
- recipient `確認してみる`
- reply deadline passes
- old `やる`

Expected: original assignment remains; old action stale; reproposal available.

### Scenario C — Consultation

- `18:30なら可能`
- one side confirms
- other has not

Expected: no assignment change until same revision both confirm.

### Scenario D — Mostly done

- evening has occurrence-end + until-done + deadline tasks
- user `大体やった`

Expected: no child completion; only meaningful weak carryover; no failure stats.

### Scenario E — Duplicate-sensitive medicine

- papa completes medication
- mama still has old LINE

Expected: neutral `対応済み`, stale action cannot duplicate completion.

### Scenario F — Anyone claim takeover race

- papa claim
- mama takeover while papa completes

Expected: serializable coherent state; no duplicate action/assignee rewrite.

### Scenario G — Rule change with protected agreements

- future weekday rule changes
- six protected occurrences

Expected: one bulk confirmation summary, protected rows unchanged until resolution.

### Scenario H — Google protected conflict

- Family Ops protected event
- Google time changed

Expected: candidate diff; prep not silently shifted.

### Scenario I — Nursery correction

- original Codmon schedule
- revised screenshot changes date

Expected: current vs source diff; confirmed update shifts eligible prep only.

### Scenario J — Test mode

- simulated mama accepts request

Expected: operator sees synthetic reply; no production spouse/Google/outbox effect.

### Scenario K — Concurrent channels

- PWA completes task
- old LINE postback seconds later

Expected: one completion; current performer preserved.

## 11. Notification acceptance budget

Review and implementation must measure message count for representative week.

Goal is not a hard numeric SLA, but defaults should approximate:

- 2 scheduled anchors/day max under normal settings
- no extra completion push for normal chores
- exception pushes only when user behavior/response is affected

Test scenarios should count generated notification intents and actual LINE sends, including bundling/quota fallback.

## 12. Performance expectations

Household scale is small, but Today must feel immediate.

Detailed implementation target guidelines:

- DailyBrief DB computation bounded to household + near-date scope
- avoid N+1 per task/provider
- no Google network call in normal Today request; use cache + freshness signal
- no vision processing inline in LINE webhook
- image processing async
- morning/evening dispatch should not render all households in one unbounded transaction

## 13. Privacy acceptance

Before nursery intake production:

- storage private policy verified
- cross-household signed access test
- raw delete path tested
- logs inspected for OCR/raw image data
- third-party unrelated names not durable structured rows
- retention/backup runbook documented

## 14. Operational runbooks required before release

Implementation closeout must create/update:

- migration deployment/recovery
- LINE notification/outbox diagnostics
- Google OAuth/reauth/sync conflict
- image processing/privacy deletion
- test-mode activate/close/real spouse transition
- stale/duplicate mutation diagnosis
- feature gate rollback

## 15. Independent implementation reviews

After detailed design GO, implementation should be reviewed by logical milestones rather than one massive PR.

Recommended review gates:

- Domain/schema + migration
- Request/assignment/actual core
- Daily UX + notifications
- Google Authority
- Nursery intake
- Test mode + final production audit

Each review fresh-reads canonical Requirements + current detailed design.

## 16. Definition of production-ready

Feature set is production-ready only when:

- canonical docs reflect actual behavior
- pending migrations applied in order
- Edge deployed/auth matrix aligned
- cron/scheduled jobs active as intended
- PWA production smoke pass
- LINE real/synthetic flows pass as appropriate
- Google sync/write audit pass for changed areas
- no test data leakage
- data reconciliation checks pass
- rollback/feature-disable path verified

