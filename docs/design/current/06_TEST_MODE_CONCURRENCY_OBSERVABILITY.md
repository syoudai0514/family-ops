# 06. One-user Test Mode, Concurrency, Security, and Observability

## 1. Purpose

本書は、通常業務ロジックを再利用しながら:

- one-user LINE testでproductionを汚さない
- duplicate/stale/concurrent操作でstateを壊さない
- auditとprivacyを維持する
- 障害時にどこまで処理されたか判別できる

ための横断設計を定義する。

## 2. Execution context

Every command is executed with a server-derived context:

```text
execution_context:
  mode: production | test_simulation
  operator_user_id: UUID
  actor_kind: real_user | simulated_member | system
  real_actor_user_id?: UUID
  test_context_id?: UUID
  simulated_role?: papa | mama
```

Client body cannot self-assert `mode=test_simulation` without server validating active context owned by the operator/household.

## 3. Simulated actor identity

Do not create a fake Supabase Auth user or real household member row for the simulated spouse.

Why:

- fake auth identity could pass normal RLS/business checks accidentally
- later real spouse onboarding could be confused with test consent
- production analytics/member count becomes contaminated

Instead:

- operator is a real authenticated user
- simulated member is a domain actor reference bound to test context
- domain audit records actor kind + test context

## 4. Same domain logic, different side-effect adapter

Command core:

1. validate domain state
2. compute mutation result/events/intents
3. persist test-scoped or production state as designed
4. route side effects through `ExecutionSideEffects`

Adapter behavior:

### Production adapter

- production user_notifications
- production LINE outbox
- Google write queue
- normal analytics eligibility

### Test simulation adapter

Allowed:

- operator-facing synthetic rendered message
- test-scoped audit/data
- PWA test preview

Forbidden:

- production recipient LINE push
- production notification outbox insertion
- Google Calendar write/create/update/delete
- real spouse request/ack/consent
- production analytics inclusion

If forbidden effect is attempted, fail closed with `TEST_SIDE_EFFECT_FORBIDDEN` and structured log.

## 5. Synthetic LINE delivery — Final GO MEDIUM-3

Requirements explicitly want one LINE talk to simulate both sides.

Synthetic delivery can use the LINE API to the **operator's already linked LINE user only**, but it is not a production recipient notification.

Mandatory safeguards:

- destination resolved from operator user, never simulated role
- rendered message prefix: `🧪 テスト: ママへの通知` / `🧪 テスト: パパへの返答`
- `delivery_mode=test_simulation`
- separate dedup namespace
- never consume/resolve a production user_notification as sent
- never write production notification outbox row
- provider response/audit tagged test context

Implementation options:

1. dedicated `test_delivery_outbox`
2. shared physical outbox with hard DB check/partition and different adapter

Review preference: dedicated logical queue/table or strongly separated row type with DB constraint. A boolean loosely passed through renderer is insufficient.

## 6. Test data lifecycle

All test-generated mutable business rows either:

- contain `test_context_id`, or
- reference an aggregate that is test-scoped

Production default queries include `test_context_id IS NULL` unless explicit Test UI.

Test mode UI clearly indicates active simulation.

Closing context:

- stops new simulated commands
- preserves test audit for debugging until retention
- does not convert test records into production

## 7. Real spouse onboarding transition

When real spouse joins/links LINE:

- simulated consent does not become real consent
- active simulated request attempts do not become production requests
- simulated assignments do not silently become real spouse agreements
- test tasks may be discarded/archived as test records; current real operational tasks are derived only from production state

If user wants to carry a useful unresolved item forward:

- system generates a **new production proposal**
- user reviews
- real spouse receives/accepts normally

No database `UPDATE simulated_actor -> real_user_id` migration.

## 8. Test-mode coverage expectations

Must simulate at least:

- request send -> checking -> accept
- decline with comment
- consultation both confirmations
- assignment change already agreed + `[違う]`
- anyone claim/takeover
- group reconciliation
- share/handover ack
- stale postback
- duplicate webhook

Google/nursery flows can be previewed, but simulated actor must not write Google.

## 9. Idempotency layers

Use existing v6 pattern but distinguish IDs.

### 9.1 Provider webhook dedup

LINE webhook inbox unique provider/webhook event identity.

Google channel notifications coalesce sync jobs.

### 9.2 User operation receipt

`operation_id + actor` canonical mutation receipt.

Same operation + same canonical request hash -> replay prior result.

Same operation + different request -> `IDEMPOTENCY_CONFLICT`.

### 9.3 Business identity

Some actions also require semantic uniqueness:

- request attempt acceptance one terminal transition
- recurrence logical occurrence key unique
- Google remote event deterministic ID/write operation
- scheduled dispatch receipt unique per household/slot
- source document processing version unique

Operation receipt alone does not replace business unique constraints.

## 10. Optimistic concurrency

Mutable aggregates expose `revision`.

Commands requiring stale protection carry `expected_revision`.

Transaction:

1. lock row
2. compare expected/current
3. mismatch -> no mutation
4. return safe current summary and `AGGREGATE_REVISION_CONFLICT`

Use on:

- task assignment/claim/correction
- request attempt action/terms revision
- family event edit/candidate resolution
- info correction

Simple idempotent read/mark-read may not need revision.

## 11. LINE postback token/content

Postback contains minimum opaque references:

- action code
- aggregate/attempt/session ID
- expected revision/terms revision where required
- optional signed/validated short context token if payload size/security warrants

Never include:

- raw partner message
- OAuth/auth token
- storage signed URL
- Google data payload

Server re-derives household/actor/current state.

## 12. Stale action examples

### Request expired

Old `やる`:

- no accept
- `REQUEST_ATTEMPT_STALE`
- current assignment preserved
- reply with latest state + `再提案`

### Task already completed

Old `完了`:

- no duplicate event/performer overwrite
- return already-completed summary
- if user claims joint execution, explicit secondary action required

### Claim changed

Old claimant presses release after takeover:

- revision mismatch
- do not clear new claimant

### Candidate changed

User opens old image/Google diff and target changed:

- candidate stale
- refresh diff

## 13. Claim takeover race

Scenario:

- papa has claim
- mama presses takeover
- papa completes at same time

Both commands lock same task aggregate.

If completion commits first:

- takeover sees completed -> fails/returns completed

If takeover commits first:

- claimant becomes mama
- papa completion command must not be rejected solely because not claimant if he actually performed; however UI should show conflict and require explicit performer semantics depending on command origin.

Recommended rule:

- claim coordinates intent, not legal permission to complete
- any household adult may report actual completion
- if performer differs from current claimant, transaction completes but records mismatch event and neutral state; no assignment rewrite

This avoids “claim made actual truth impossible”.

## 14. Completion concurrency

Two adults complete same task concurrently.

First transaction:

- task -> completed
- performer A

Second transaction:

- sees completed
- cannot silently replace A
- returns `TASK_ALREADY_COMPLETED` with performer summary
- offers explicit `共同でやった` if appropriate

If both actually jointly performed and one command contains both performers, participant rows are atomic.

## 15. Duplicate-sensitive stale checklist

Safety-critical task such as medication:

- DailyBrief generated from latest task state
- old LINE postback still validated server-side
- completed task action returns already-done message
- neutral immediate completion intent can inform other adult

No system should rely only on recipient visually refreshing old LINE content.

## 16. Notification delivery idempotency

Maintain existing durable outbox rules:

- semantic notification intent unique/dedup key
- outbox fixed provider retry key
- retries same payload/key before expiry
- 409 provider duplicate reconciles
- ambiguous after retry expiry -> delivery_unknown

Rendering latest state:

For state-sensitive notification, create intent early but render close to dispatch or verify aggregate revision before send.

If state no longer relevant:

- suppress/expire intent
- do not deliver stale reminder late

## 17. Scheduled dispatch idempotency

Morning/evening dispatch receipt identity:

`{household}:{recipient}:{local_date}:{brief_kind}:{schedule_version}`

Same cron minute rerun -> same receipt/no duplicate push.

If schedule setting changes after old receipt but before new slot, version distinguishes intentionally rescheduled dispatch while business rules prevent two contradictory same-day sends where not desired.

## 18. Audit model

Audit must answer:

- who/what actor initiated action?
- production or test?
- what aggregate changed?
- old/new semantic state?
- request/attempt/source reference?
- operation id?
- when?

Do not audit secrets/raw provider payload unnecessarily.

Task audit reuses `task_events`.

Request/event/source may use dedicated append-only event tables or a common safe audit event table. Review should prefer minimum number of parallel histories while retaining query clarity.

## 19. Recorder vs performer privacy/meaning

History can retain:

- performer(s)
- recorder

Normal UI shows performer where needed, recorder only in correction/audit detail.

Do not turn recorder into “who claims credit”.

## 20. Security / RLS invariants

Continue v6 security model:

- browser SELECT only on RLS-safe public views/tables
- business writes revoked from authenticated client
- mutations via Edge + server transaction
- private schema unavailable to browser
- service-role privileges minimal
- SECURITY DEFINER only justified/set empty search path

New tables require household composite isolation wherever practical.

## 21. Source image access security

- private storage bucket
- signed URL generated only after current household membership authorization
- short TTL
- object key cannot be supplied to generic unauthenticated fetch
- raw-deleted source returns gone, not stale signed reissue
- logs avoid signed URL query tokens

## 22. Test/production leakage database guards

Detailed DDL should add hard checks where possible:

- production outbox row `test_context_id IS NULL`
- family event external Google write job cannot reference test-context event
- simulated actor ref requires test_context_id
- production request recipient must be real household member; simulated role is stored in separate test fields/context

Application if-statements alone are insufficient for high-risk boundary.

## 23. Observability

Structured metrics/logging dimensions:

### Domain

- mutation success/conflict/idempotent replay
- request attempt expiry/stale tap
- claim conflict/takeover
- reconciliation mode counts (no ranking by spouse)
- candidate accepted/rejected/stale

### Delivery

- production LINE sent/fallback/unknown/quota blocked
- synthetic test deliveries separately
- stale intent suppressed
- duplicate-sensitive immediate notice

### Google

- sync age/jobs/dead
- authority conflicts created
- write ETag conflicts

### Intake

- processing latency/failure
- ambiguous child/school rate
- user correction rate
- raw deletion counts

Do not emit extracted third-party names or raw document text into logs.

## 24. Alerts

Production alert conditions:

- notification outbox dead/lease backlog
- Google sync dead/reauth spike
- test-context row attempting production outbox/Google write (security alert)
- candidate apply revision conflict surge
- webhook signature failures spike
- raw storage cleanup failures

## 25. Retention

Retain existing v6 operational cleanup rules unless overridden.

New items:

- test synthetic delivery logs: short operational retention, configurable
- request attempts: product history retention consistent with request history; not aggressively hard-delete while referenced by assignment audit
- reconciliation sessions: sufficient for history/reconciliation semantics; configurable archival later
- change candidates: terminal candidates retain provenance for conflict history; sensitive raw payload minimized
- source extraction intermediate model outputs can be shorter retention than confirmed structured facts

Raw image retention follows product-configured policy and user delete.

## 26. Backup/restore semantics

Backup must include canonical business state/history.

For raw image deletion:

- normal app path must not restore deleted object
- immutable backup physical expiration follows backup policy
- restore runbook must reapply logical `raw_deleted_at` state before exposing restored storage

Test data remains test-tagged after restore.

## 27. Failure mode examples

### Worker dies after DB mutation before LINE call

- domain state committed
- intent/outbox persists
- worker retry sends or suppresses based on expiry/latest state

### LINE sends but response lost

- fixed retry key/409 reconcile
- no duplicate business mutation

### AI intake crashes

- raw source remains private
- extraction failed/retryable
- no event/task mutation before confirm

### Google webhook duplicate

- sync job coalesced
- candidate generation idempotent by source/version/hash

### PWA offline/stale tab

- mutation revision conflict
- current state refreshed inline

## 28. Mandatory security/concurrency test matrix

1. duplicate LINE webhook -> one request attempt
2. same postback twice -> one transition
3. expired request old accept -> no resurrection
4. two consultation confirmations on different revisions -> no acceptance
5. claim/takeover race
6. takeover/completion race
7. two concurrent completions -> no performer overwrite
8. LINE old completion after PWA completion
9. candidate acceptance after target edit -> stale
10. Google change after human protection -> candidate only
11. simulated request -> no production outbox
12. simulated event -> no Google write
13. synthetic LINE always targets operator
14. real spouse onboarding -> no simulated consent migration
15. source image cross-household access denied
16. raw-deleted source signed URL cannot be regenerated
17. logs contain no source raw text/secret
