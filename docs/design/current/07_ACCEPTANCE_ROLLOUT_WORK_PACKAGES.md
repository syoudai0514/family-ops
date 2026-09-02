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
- `待ち` attention truth/next-check/deadline behaviorがschema/command/DailyBriefで閉じる
- simulated actor identityがActorRefとして全actor-bearing truthで一貫する
- migration strategyが既存production dataを破壊しない
- semantic point-of-no-return後のsafe feature-offが定義済み
- one-user testのactor/side-effect boundaryが実装可能
- concurrency/idempotencyのuser-visible resultが定義済み
- three Final-GO MEDIUM carryoversがacceptance criteriaに組み込まれている

MEDIUM以下は実装work packageのacceptanceへ明示的にcarryできる場合のみGO可。

## 3. Implementation principles

- no direct main push
- no production data reset/delete
- existing migration rewrite禁止
- pending/new migrationのみtimestamp順
- Edge Function auth matrixを更新してから新function deploy
- feature/cutoverはreversible **within its declared rollback class**
- new-only semantic state発生後にlegacy current-truth read/writeへ戻さない
- one domain aggregateをold/new双方が自由に書くdual-write期間を作らない
- runtime behaviorがRequirements Baselineを変更する場合、codeより先/同PRでBaseline更新+review

## 4. Rollback classes and point of no return

### R0 — pre-semantic-cutover

Additive schema/backfillのみ。new-only semantic stateはまだproductionに存在しない。

- old runtimeへ完全に戻せる
- additive columns/tablesは残ってよい
- backfill rowsは無視/forward-fix可能

### R1 — new command enabled, before first new-only state

Old public endpointはnew command adapterへroute済み。まだchecking/consulting/anyone claim/multiple performer/waiting/mostly-done等のnew-only stateはproductionに生成されていない。

- UI feature-off可能
- old semantic mutation routeを復活させない
- if needed, commands can be paused before first P1 state

### P1 — semantic point of no return

最初のnew-only semantic stateがproductionに生成された時点。

P1後:

- **legacy current-truth readへのrollback禁止**
- **legacy semantic writeへのrollback禁止**
- feature-off means `pause new mutations + render canonical new truth through compatibility/degraded projection`, or forward-fix
- physical schema rollbackは行わない

Work package/release checklistはP1を記録する。

## 5. Work package order

### WP-DD1 — Additive domain schema foundation

Scope:

- domain ActorRef foundation
- task instance assignment mode/source/claim/revision
- task attention (`active|waiting`, note, next-check)
- task current `outcome_reason`
- task definition expectation/carryover/duplicate sensitivity
- actual participants using ActorRef
- reconciliation sessions/items using ActorRef
- request attempts/confirmations using ActorRef
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
- real-user ActorRef idempotent backfill path exists
- production aggregate cannot reference simulated ActorRef
- test aggregate requires same test-context ActorRef
- waiting constraints enforce nonterminal-only
- skipped new rows can hold recognized outcome_reason
- existing app still runs against old read/write path
- rollback class R0 documented

### WP-DD2 — Backfill and compatibility adapters

Scope:

- current household members -> real ActorRefs
- current task assignment -> new assignment ActorRef snapshot
- actual_completed_by_id -> participant rows
- request rows -> request attempt representation
- handover defaults
- current task default policy snapshots

Acceptance:

- idempotent re-run
- row counts/reconciliation report
- no guessed anyone assignment
- no guessed performer
- legacy skipped reason not guessed
- completed request lacking linked task flagged, not fabricated
- request mismatch audit includes:
  - missing link
  - duplicate/invalid link
  - request terminal state vs linked task state mismatch
  - deterministically detectable timestamp inconsistency
- anomaly row is quarantined/reported; no auto inferred repair
- backfill can be audited per household
- semantic cutover blocked for unresolved anomaly unless explicitly classified legacy-unknown

### WP-DD3A — Test identity and side-effect sandbox foundation

**Dependency:** must complete before any actual-household one-user test and before WP-DD3 command flows are exercised in test simulation.

Scope:

- server-derived `execution_context`
- ActorRef resolution for real/simulated/system
- simulated actor persistence across assignee/claimant/performer/recorder/request/confirmation/reconciliation/audit
- production/test scope DB guards
- `ExecutionSideEffects` hard boundary
- production outbox/Google/real consent fail-closed guards
- minimal operator synthetic delivery path sufficient for domain test

Acceptance:

- fake auth user/member not required
- simulated mama can be assignee -> claimant -> performer -> request recipient/confirmer without operator ID substitution
- production row cannot reference simulated ActorRef
- simulated mutation cannot insert production outbox/Google write/real consent
- operator synthetic message is clearly `🧪` and test-scoped
- production analytics excludes test by default
- Final-GO MEDIUM-3 PASS at foundation level

### WP-DD3 — Transaction command layer + concurrency

**Dependency:** WP-DD3A test foundation available for one-user validation.

Scope:

- task complete/correct
- set/update/resume waiting
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
- waiting next-check update/resume stale-safe
- task + audit + notification intent atomic
- skipped current outcome_reason deterministic for new writes
- LINE/PWA call same transaction contract
- actual-household one-user test can execute with side effects sandboxed

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
8. simulated recipient flow uses simulated ActorRef, never operator identity

**P1 warning:** first production checking/consulting state makes legacy Requests current-truth read unsafe. Record cutover checkpoint before enabling.

### WP-DD5 — Actual/reconciliation + History semantics

Scope:

- multiple performers
- all_done/mostly_done/individual
- carryover result certainty
- current outcome_reason read/history
- support analytics derived
- correction history

Acceptance:

- `大体やった` child status unchanged
- occurrence_end unknown closes without failure metric
- until_done appears as weak `結果未確認`
- Final-GO MEDIUM-1 compact follow-up only when meaningful
- household completion count remains one with joint performers
- assignment change before completion not counted as support
- `今回は不要` and `できなかった` remain distinguishable in current read/History/analytics
- simulated performer/recorder retained as test ActorRef only

### WP-DD6 — Shared Daily Brief + LINE/PWA channel convergence

Scope:

- server DailyBrief read model
- waiting_checks / hard-deadline risk
- PWA Today cutover
- LINE `今日`
- morning 06:30 / weekend holiday 09:00
- evening 20:30
- partner summary
- deep links

Acceptance:

- same underlying task/request state in LINE/PWA
- waiting future-check task excluded from normal incomplete nag
- next_check due resurfaces as `確認日`, not failure
- hard due risk visible while waiting
- waiting remains waiting until explicit resume/update
- no frontend-only assignment/calendar computation
- evening does not replay completed morning details
- PWA mutation no scroll reset/full reload
- stale deep link displays current state

### WP-DD7 — Notification policy and duplicate-sensitive safety

Scope:

- intent metadata/policy engine
- immediate vs digest
- neutral duplicate-sensitive completion
- waiting check/deadline notification policy
- stale intent suppression
- bundling

Acceptance:

- normal partner task completion no praise push
- medication completion informs at-risk other adult with neutral `対応済み`
- transport/purchase/submission category can be configured duplicate-sensitive
- waiting task does not routine-nag before check date unless hard deadline risk
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
- prep task waiting uses Task attention state rather than parallel event task status

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

### WP-DD10 — One-user test UX completion and real-spouse transition

Core test identity/guard is already required by WP-DD3A. This package completes the operator experience and transition, not the foundational safety model.

Scope:

- richer synthetic operator delivery UX
- simulation management UI
- test history/filtering
- real spouse transition flow
- close/archive test context

Acceptance:

- domain state machine same as production
- synthetic LINE reaches operator with `🧪`
- no production outbox
- no Google write
- no real spouse consent
- production analytics default excludes test
- real spouse join does not inherit simulated agreement
- unresolved useful item can only become a **new reviewed production proposal**
- Final-GO MEDIUM-3 remains PASS

### WP-DD11 — Production migration/cutover audit

Scope:

- feature gates
- old endpoint adapters
- compatibility/degraded projections
- semantic P1 checkpoints
- production audit
- monitoring/runbook

Acceptance:

- no old/new divergent mutation route
- current production rows reconcile to new reads
- no orphan accepted requests
- no completed task participant loss
- notification duplication audit clean
- every enabled capability declares R0/R1/P1 state
- after P1, feature-off never restores legacy current-truth semantics
- degraded/read-only compatibility projection can render canonical new state during incident
- forward-fix/mutation-pause runbook exists

## 6. Feature gate strategy

Prefer capabilities rather than one giant `vNext` boolean.

Potential gates:

- `test_actor_foundation_v1`
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
- gate metadata records whether capability has crossed P1
- P1-crossed feature cannot route to legacy current-truth read/write; only pause/degraded projection/forward-fix

## 7. Rollout order

Recommended production rollout:

1. schema + ActorRef + backfill only, feature off (R0)
2. test execution-context/actor/side-effect sandbox foundation (WP-DD3A)
3. domain commands/concurrency tests under sandbox
4. internal one-user test on actual household with external side effects sandboxed
5. requests/actual semantics — record P1 before first new-only state
6. DailyBrief/PWA Today including waiting behavior
7. scheduled LINE consolidation
8. duplicate-sensitive notifications
9. event/Google Authority
10. nursery intake
11. one-user UX polish/real spouse onboarding only after test-mode acceptance

Google/event layer may be developed in parallel after domain primitives but production cutover should occur after current task/request truth is stable.

## 8. Production safety gates

Before each migration/deploy:

- current main SHA recorded
- production migration history read
- target migration pending status confirmed
- production schema preconditions queried
- no `db reset`
- no applied migration re-run
- backup freshness checked for schema-affecting work
- rollback class + P1 status recorded for affected capability

After:

- migration history matches expected
- schema constraints exist
- Edge functions deployed only if migration compatible
- cron/outbox health
- PWA production smoke
- LINE test for changed path
- Google sync audit if changed
- canonical read compatibility verified for P1-crossed features

## 9. Data reconciliation reports

Implementation should produce read-only audit queries/scripts for:

### Tasks

- completed task count vs participant backfill
- participant missing legacy cases
- invalid assignment mode/assignee ActorRef combinations
- production task referencing simulated ActorRef = zero
- anyone with claimant on terminal task
- waiting on terminal task = zero
- skipped new row without recognized outcome_reason = zero

### Requests

- logical request count
- active attempts >1 violation
- accepted/completed legacy request without linked task
- duplicate/invalid linked task relation
- legacy request state vs linked task mismatch
- request/link timestamp inconsistency report
- production request referencing simulated ActorRef = zero

### Recurrence

- overlapping active rules
- future `assignment_source=rule` vs protected count

### Test

- test_context row in production outbox/Google operations = must be zero
- simulated actor mirrored as operator real-user identity = must be zero
- simulated actor referenced from production aggregate = zero

### Sources

- raw_deleted source with live storage object = cleanup lag
- cross-household source references = zero

## 10. Test pyramid

### SQL/domain unit tests

- state constraints
- ActorRef scope constraints
- waiting/outcome constraints
- RPC transaction semantics
- RLS
- idempotency
- revision conflicts

### Edge integration tests

- JWT actor binding
- simulated ActorRef resolution
- error envelopes
- test side-effect guard
- outbox intent creation

### PWA component/integration

- request actions
- Today sections
- waiting controls
- reconciliation
- deep-link state restoration

### LINE flow tests

- webhook dedup
- postback stale handling
- waiting next-check action
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

## 11. Mandatory end-to-end scenario suite

### Scenario A — Normal weekday

- 06:30 brief
- morning bulk complete
- daytime share
- 20:30 evening
- all done

Expected: minimal operations, no duplicate self notifications.

### Scenario B — Waiting / next-check / deadline

- photo studio inquiry task -> `待ち`
- note + next-check 9/10 + due 9/15
- normal days pass
- 9/10 DailyBrief resurfaces as check, not failure
- user extends waiting or resumes
- if still waiting near 9/15, risk warning appears

Expected: no normal nag while waiting, no automatic resume, due risk preserved.

### Scenario C — Request checking expiry

- pickup change request
- recipient `確認してみる`
- reply deadline passes
- old `やる`

Expected: original assignment remains; old action stale; reproposal available.

### Scenario D — Consultation

- `18:30なら可能`
- one side confirms
- other has not

Expected: no assignment change until same revision both confirm.

### Scenario E — Mostly done

- evening has occurrence-end + until-done + deadline tasks
- user `大体やった`

Expected: no child completion; only meaningful weak carryover; no failure stats.

### Scenario F — Duplicate-sensitive medicine

- papa completes medication
- mama still has old LINE

Expected: neutral `対応済み`, stale action cannot duplicate completion.

### Scenario G — Anyone claim takeover race

- papa claim
- mama takeover while papa completes

Expected: serializable coherent state; no duplicate action/assignee rewrite.

### Scenario H — Rule change with protected agreements

- future weekday rule changes
- six protected occurrences

Expected: one bulk confirmation summary, protected rows unchanged until resolution.

### Scenario I — Google protected conflict

- Family Ops protected event
- Google time changed

Expected: candidate diff; prep not silently shifted.

### Scenario J — Nursery correction

- original Codmon schedule
- revised screenshot changes date

Expected: current vs source diff; confirmed update shifts eligible prep only.

### Scenario K — Simulated actor identity E2E

- real papa -> simulated mama request
- simulated mama checking -> accepts
- linked task assigned to simulated mama
- simulated mama claims/performs/records
- consultation confirmation uses both real/simulated ActorRefs

Expected: no fake auth/member; no operator identity substitution; every row test-scoped; no production side effects.

### Scenario L — Concurrent channels

- PWA completes task
- old LINE postback seconds later

Expected: one completion; current performer preserved.

### Scenario M — Semantic cutover incident

- request feature crosses P1 with a `checking` state
- unrelated runtime defect requires feature-off

Expected: legacy Requests UI with `引き受ける/断る` is **not** restored as current truth. New mutations may pause; canonical new state is shown via compatibility/degraded projection until forward-fix.

### Scenario N — Outcome reason

- one occurrence marked `今回は不要`
- another marked `できなかった`

Expected: both may be skipped operationally but current read/History/analytics preserve distinct reasons.

## 12. Notification acceptance budget

Review and implementation must measure message count for representative week.

Goal is not a hard numeric SLA, but defaults should approximate:

- 2 scheduled anchors/day max under normal settings
- no extra completion push for normal chores
- waiting does not add daily nag before check/deadline risk
- exception pushes only when user behavior/response is affected

Test scenarios should count generated notification intents and actual LINE sends, including bundling/quota fallback.

## 13. Performance expectations

Household scale is small, but Today must feel immediate.

Detailed implementation target guidelines:

- DailyBrief DB computation bounded to household + near-date scope
- waiting due-check query indexed/bounded
- avoid N+1 per task/provider
- no Google network call in normal Today request; use cache + freshness signal
- no vision processing inline in LINE webhook
- image processing async
- morning/evening dispatch should not render all households in one unbounded transaction

## 14. Privacy acceptance

Before nursery intake production:

- storage private policy verified
- cross-household signed access test
- raw delete path tested
- logs inspected for OCR/raw image data
- third-party unrelated names not durable structured rows
- retention/backup runbook documented

## 15. Operational runbooks required before release

Implementation closeout must create/update:

- migration deployment/recovery with R0/R1/P1 semantics
- semantic feature-off / mutation-pause / degraded projection
- LINE notification/outbox diagnostics
- Google OAuth/reauth/sync conflict
- image processing/privacy deletion
- test-mode activate/close/real spouse transition
- stale/duplicate mutation diagnosis

## 16. Independent implementation reviews

After detailed design GO, implementation should be reviewed by logical milestones rather than one massive PR.

Recommended review gates:

- Domain/schema + ActorRef/waiting/migration
- Test sandbox foundation
- Request/assignment/actual core
- Daily UX + notifications
- Google Authority
- Nursery intake
- Test UX + final production audit

Each review fresh-reads canonical Requirements + current detailed design.

## 17. Definition of production-ready

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
- waiting/outcome reason E2E pass
- semantic P1/feature-disable path verified
- no legacy current-truth rollback after P1