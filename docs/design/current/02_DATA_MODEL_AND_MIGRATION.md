# 02. Data Model and Migration Strategy

## 1. Scope

本書は、Requirements Baseline と ADR 0013 を CURRENT `main` 上へ安全に実装するための schema semantics / migration strategy を定義する。

DDLの最終SQL名そのものは実装レビューで決めるが、current truth・互換性・cutover順序は本書と `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md` で確定する。

原則:

- production data delete禁止
- `supabase db reset`禁止
- applied migration rewrite禁止
- pending/new migrationのみtimestamp順
- additive/evolution migration優先
- backfillはidempotent
- 推測backfill禁止
- old/new truthを長期間dual-writeしない
- aggregate単位でcanonical read/writeを同時cutover
- P1後にlegacy current-truth read/writeへ戻さない
- physical legacy cleanupは別reviewed migration

CURRENT物理テーブルの網羅dispositionは `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md` の **50 tables = public 27 / private 23** を正とする。

---

## 2. CURRENT table reuse boundary

高レベル分類:

- Household/Auth/RLS: KEEP
- Task/Recurrence/Request/Handover/Shopping/Routine schedule: EVOLVE
- old routine check-in evidence: SUPERSEDE
- Google OAuth/watch/sync/cache/occurrence/idempotency: KEEP
- CURRENT Task→Google mirror: BRIDGE（Task-owned projectionのみ）
- CURRENT old-target provider deletion queue: BRIDGE（bounded destructive provider mutation path）
- CURRENT permission-loss orphan record: KEEP（provider identity audit/observation only; not writable ownership）
- new Family Event Authority: additive canonical domain
- pending actions/raw input/outbox/receipts: reuse with bounded EVOLVE

`household_task_categories`はCURRENT household task taxonomyとして再利用するが、Event Authority・school context・assignment truthにはしない。

`private.family_ops_calendar_mirrors` / `private.family_ops_calendar_target_deletions` / `private.family_ops_calendar_orphaned_mirrors` は無視しない。Task/transport→Google projection、旧write target DELETE、permission-loss auditという3つのCURRENT lifecycle責務を維持しつつ、Family Event writerとのprovider mutation ownership / transfer / orphan handlingは `08` §10 を正とする。

---

## 3. Task definition additions

`task_definitions`へ概念追加:

- `default_expectation`: `required | normal | optional`
- `carryover_policy`:
  - `occurrence_ends`
  - `until_done`
  - `until_deadline`
  - `separate_next_occurrence`
- `duplicate_sensitivity`:
  - `normal`
  - `avoid_duplicate`
  - `safety_critical`
- `early_completion_policy`:
  - `none`
  - `recommended`
  - `required_before`
- optional `default_duration_minutes`

毎occurrenceで変わり得るため、materialization時にtask instanceへsnapshotする。

薬・送迎・購入・提出などをcategory名hard-codeだけで安全判定しない。

---

## 4. Recurrence rule evolution

CURRENT `recurrence_rules` の effective dating/versioningを維持する。

### 4.1 Materialized assignment result

Task instanceへsnapshot:

- `assignment_mode`: `person | unassigned | anyone`
- `planned_assignee_actor_ref_id` nullable
- legacy `planned_assignee_id` nullable — production real-user compatibility mirror only
- `assignment_source`: `rule | explicit_override | agreement | manual | legacy_snapshot` 等

既存 `fixed/dropoff_assignee/pickup_assignee/nonpickup_adult/unassigned` はresolution strategyとして維持可能。

`anyone` ruleを追加する場合:

- assignment_mode=`anyone`
- planned assignee actor ref=null

### 4.2 Protected future occurrence

explicit agreement/manual override済みfuture occurrenceはrule再計算でsilent rewriteしない。

rule changeが自動更新できるのは、原則 `assignment_source='rule'` のfuture occurrenceのみ。

過去actualは一切書き換えない。

---

## 5. Task instance evolution

`task_instances` canonical operational snapshot:

- `assignment_mode text not null`
- `assignment_source text not null`
- `planned_assignee_actor_ref_id uuid null`
- `active_claimant_actor_ref_id uuid null`
- legacy `planned_assignee_id` compatibility mirror
- `claimed_at timestamptz null`
- `expectation text not null`
- `carryover_policy text not null`
- `duplicate_sensitivity text not null`
- `early_completion_policy text not null`
- `available_from` nullable
- current `due_at` reuse
- `attention_state = active | waiting`
- `waiting_note text null`
- `next_check_at timestamptz null`
- `outcome_reason text null`
- `revision bigint/int not null default 1`
- optional `event_id uuid null`
- **direct `test_context_id uuid null`**
- optional non-secret `source_context jsonb`

Constraints/invariants:

- `person` -> planned assignee ActorRef required
- `unassigned|anyone` -> planned assignee ActorRef null
- claimant allowed only for open `anyone`
- terminal task has no active claimant
- waiting allowed only todo/in_progress
- terminal transition clears current waiting metadata; audit retains history
- skipped new writes require recognized outcome reason
- production row cannot reference simulated ActorRef
- test row may reference simulated ActorRef only from same household/test context

`actual_completed_by_id` is **not** new truth.

### 5.1 CURRENT completion CHECK migration

CURRENT physical CHECKs make participant-first completion impossible without a forward constraint migration.

Phase 1 must inspect production catalog and replace those CHECKs before new completion writes. Binding physical rule is `08` §3:

- subtasks parent legacy actor remains null
- production whole completed has canonical participant(s) + one technical compatibility-primary real mirror while old reader exists
- test/simulated whole completed may keep legacy real-user mirror null
- completed/completed_at integrity remains

No applied migration rewrite and no physical drop of legacy column.

---

## 6. Task audit / assignment / claim history

Current assignment/claim snapshot is Task current truth; history is append-only.

Prefer extending `task_events` rather than creating a competing assignment-history table.

Event examples:

- `assignment_changed`
- `assignment_agreed`
- `claim_acquired`
- `claim_released`
- `claim_taken_over`
- `assignment_rule_recomputed`
- `actual_corrected`
- `waiting_started`
- `waiting_updated`
- `waiting_resumed`
- `rescheduled`

Payload may contain prior/new mode, ActorRefs, source, request/attempt ref, revision, waiting metadata, schedule before/after.

Task event canonical actor is ActorRef. Legacy real-user actor column may remain production compatibility mirror.

---

## 7. Domain actor identity

新規 `domain_actor_refs` を全actor-bearing semanticsの共通永続identityとする。

Conceptual fields:

- id
- household_id
- actor_kind: `real_user | simulated_member | system`
- real_user_id nullable
- test_context_id nullable
- simulated_role nullable (`papa | mama` initially)
- created_at

Invariants:

- real_user -> same-household real_user_id required; no simulated/test identity
- simulated_member -> same household + test context + simulated role; real_user_id null
- system -> explicit system actor; fake household memberを作らない
- unique household/real user and test-context/simulated-role as appropriate

Canonical ActorRef対象:

- planned assignee
- anyone claimant
- actual performer
- recorder
- request requester/recipient/creator
- request terms confirmation
- reconciliation actor
- task/audit actor
- info author/ack
- shopping assignee/claimant/participant/recorder
- source uploader/confirmer/resolver
- Family Event creator/resolver where meaningful

Authenticated operatorとdomain actorは別概念。one-user testでoperator user IDをsimulated mamaとして保存しない。

CURRENT real-user-only FK/NOT NULL compatibilityは `08_ACTORREF_LEGACY_IDENTITY_COMPATIBILITY.md` を正とする。

---

## 8. Multiple actual performers

新規 `task_actual_participants`:

- household_id
- task_instance_id
- actor_ref_id
- participation_kind default `performed`
- recorded_by_actor_ref_id
- recorded_at
- correction/removal history representation
- **direct test_context_id**
- `compatibility_primary boolean not null default false`
- unique active `(task_instance_id, actor_ref_id)`

Task completion current truth:

- task status=`completed`
- completed_at
- canonical participant row(s)

Normal new completion requires at least one known performer。Legacy completed actor unknownは推測せず `legacy_unknown_performer` treatment。

### 8.1 Legacy `actual_completed_by_id`

Migration:

1. ActorRef + participant table add
2. real-user ActorRefs backfill
3. legacy non-null actual actor -> participant backfill
4. participant-first new command enabled only after CURRENT CHECK replacement
5. production whole completion mirrors technical compatibility-primary real participant to legacy actor while needed
6. simulated/test never mirror fake real user
7. canonical reads cutover
8. physical cleanup later separate review

Compatibility-primary selection is deterministic but product-invisible; `08` §3.2 governs.

---

## 9. Group reconciliation evidence

`大体やった` is not a child-task status.

### `task_reconciliation_sessions`

- id
- household_id
- actor_ref_id
- target_local_date
- group_key
- response_kind: `all_done | mostly_done | individual`
- source: `line | pwa`
- **direct test_context_id**
- created_at
- supersedes_session_id nullable

### `task_reconciliation_session_items`

- household_id
- session_id
- task_instance_id
- observed_status_at_response
- display_order
- **direct test_context_id**

Purpose:

- exact task-set snapshot
- later-added tasks are not retroactively covered
- mostly_done does not alter child statuses
- session suppresses repeated detail nag

`all_done` transaction completes eligible own required+normal children and records session atomically. Optional/余力 tasks are excluded unless explicitly completed.

---

## 10. Request / Attempt model

### 10.1 `requests` logical identity

EVOLVE existing table.

Canonical fields/concepts:

- id / household_id
- requester_actor_ref_id
- recipient_actor_ref_id
- legacy requester_id/recipient_id — production compatibility only
- request_kind: `light | assignment_change`
- shared_title/shared_message
- linked_task_instance_id nullable
- assignment_task_instance_id nullable
- closed_at nullable
- **direct test_context_id**

Legacy lifecycle tuple:

- status
- accepted_at
- declined_at
- completed_at
- cancelled_at

is compatibility only for new runtime.

### 10.2 `request_attempts`

- id
- household_id
- request_id
- attempt_kind: `initial | reproposal | change | cancel`
- state:
  - pending
  - checking
  - consulting
  - awaiting_confirmation
  - accepted
  - declined
  - expired
  - cancelled
- terms_revision
- terms jsonb (partner-visible confirmed data only)
- reply_due_at
- created_by_actor_ref_id
- terminal timestamps
- revision
- **direct test_context_id**

Per Request active nonterminal attempt max 1.

Accepted initial/reproposal establishes agreement. Accepted change/cancel mutates linked Task/assignment/relationship atomically according to command semantics.

### 10.3 Consultation confirmation

`request_attempt_confirmations`:

- attempt_id
- terms_revision
- actor_ref_id
- confirmed_at
- **direct test_context_id**
- unique attempt/revision/actor

Rules:

- user who explicitly proposes exact terms is confirmed for that revision
- other required actor must confirm same revision
- AI/system summary alone implies zero confirmations
- edit increments revision and old confirmations stop applying
- one-sided confirmation never changes formal assignment

### 10.4 Late/stale action

LINE/PWA action includes request_id + attempt_id + expected revision/terms revision.

Closed/expired/stale action returns latest state and does not resurrect attempt.

### 10.5 Legacy Request physical compatibility

CURRENT `requests` CHECK constrains both status **and lifecycle timestamps**. Status-only projection is prohibited.

Binding projection is `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md` §4.

Key rule:

- before accepted agreement, current attempt projects a full CHECK-valid legacy tuple
- checking/consulting/awaiting_confirmation -> legacy pending + all terminal timestamps null
- expired -> legacy cancelled + compatibility-only cancelled_at while canonical history remains expired
- once accepted agreement exists, post-accept change/cancel attempts do **not** reproject legacy row back to pending/cancelled; new-runtime compatibility row remains `accepted + accepted_at`
- new runtime never writes Request `completed` from Task completion
- historical completed rows remain preserved/backfilled

One server-owned helper writes the full lifecycle tuple atomically.

---

## 11. Share / handover model

EVOLVE `handovers`; do not rename destructively.

Add concepts:

- info_kind: `share | handover`
- visibility: `household | self`
- valid_from / valid_until
- ack_policy: `none | required`
- related_task_id/event_id
- status: `active | superseded | expired`
- supersedes_handover_id
- canonical author ActorRef
- **direct test_context_id**

Canonical acknowledgement must be ActorRef-capable; legacy `handover_reads` may remain production compatibility projection but cannot encode simulated acknowledgement via operator ID.

---

## 12. Family Event model

New `family_events`:

- id
- household_id
- title
- status: `active | waiting_reschedule | cancelled`
- starts_at/ends_at or all-day dates
- location/details nullable
- calendar visibility/sync preference
- revision
- created_by_actor_ref_id
- **direct test_context_id**
- created_at/updated_at

Prep tasks link through task `event_id`. Prep waiting uses Task attention state; no duplicate event-prep task state machine.

### 12.1 Field Authority

Event stores schema-validated field authority for protected/followed fields, at least:

- title
- start/end/all-day
- location

Example modes:

- `human_protected`
- `external_follow`

Arbitrary user data is not allowed as uncontrolled EAV.

---

## 13. Google link / CURRENT provider lifecycle boundary

### 13.1 `family_event_external_links`

Conceptual:

- household_id
- family_event_id
- provider=`google`
- calendar_connection_id
- google_event_id
- link_mode: `family_ops_owned | external_follow`
- last external owned-field snapshot
- last external etag
- reconciliation timestamps
- unique provider/calendar/event identity

Google cache remains provider observation.

### 13.2 CURRENT Task→Google bridge / target deletion / orphan boundary

CURRENT provider lifecycle has three distinct persisted responsibilities:

1. `private.family_ops_calendar_mirrors` — Task/transport-owned provider projection bridge;
2. `private.family_ops_calendar_target_deletions` — durable old-target provider DELETE bridge;
3. `private.family_ops_calendar_orphaned_mirrors` — permission/eligibility-loss audit/observation; never writable ownership by itself.

Task mirror remains bounded to:

- transport
- explicitly Google-visible standalone Task

It is not Family Event truth.

For each provider identity, at most one **provider mutation path** may be active among Task mirror bridge, target-deletion DELETE bridge, and Family Event external-link writer. DELETE counts as a provider mutation for this invariant. An orphan record is not a writer, but an unresolved matching orphan blocks adoption/cutover until provider access and exact identity/ETag are freshly revalidated or another eligible provider event is intentionally linked.

Existing special Task mirror is not automatically converted into Family Event. Explicit adoption uses stable provider ID/ETag, resolves mirror and target-deletion pending/processing/failed/blocked state, respects live leases, prevents stale DELETE, disables Task re-enqueue for transferred ownership, then establishes Family Event external link.

Full transfer/reconciliation/destructive-delete/orphan rules: `08` §10. Implementation acceptance: `07` WP-DD8 / WP-DD11.

---

## 14. Generic change candidates

New `change_candidates`:

- id
- household_id
- target_type: family_event/task/recurrence/info
- target_id nullable for create
- source_type: google/image_fact/ai_inference/manual_import
- source_ref
- proposed_patch jsonb
- current_snapshot_hash
- status: pending/accepted/rejected/superseded/stale
- created/resolved timestamps
- resolved_by_actor_ref_id
- revision
- **direct test_context_id**

Acceptance rechecks target revision/hash. Stale candidate never blind-applies.

AI inference cannot mutate canonical entity outside candidate + human-confirmed command.

---

## 15. Children / school context

### `family_children`

- id
- household_id
- display_name
- active

### `child_school_contexts`

- id
- household_id
- child_id
- school_display_name
- class_display_name
- effective_from/effective_to
- user-confirmed recognition_aliases
- active

マサキ/すだちぐみ and ウタノ/ゆきぐみ are separate school contexts. Different school context IDs prevent accidental cross-merge.

---

## 16. Nursery/Codmon source documents

### `source_documents`

Private/RLS-protected source metadata:

- id
- household_id
- uploaded_by_actor_ref_id
- document_kind
- storage object key
- captured/uploaded timestamps
- raw_deleted_at
- retention_policy
- **direct test_context_id**

### `document_extractions`

- source document
- extraction version/provider metadata
- school-context candidate
- processing/review/confirmed/rejected/failed state

### `document_facts`

Persist only household-relevant structured facts:

- child_school_context_id
- fact_kind event/required_item/deadline/recurrence/url/note
- normalized value
- confidence band
- source locator
- fact origin=`source_explicit`

Do not persist unrelated third-party child OCR transcript as durable household business data.

### `school_preparation_rules`

Only user-confirmed rules:

- household/school context
- trigger
- preparation template
- confirmed_by_actor_ref_id
- effective period
- active

AI guess alone does not create confirmed rule.

---

## 17. Test simulation context

`test_simulation_contexts`:

- id
- household_id
- operator_user_id
- simulated role
- active/closed status
- timestamps

Core test-capable business rows listed in `08` §6 must directly store test_context_id. The older wording “test_context_id or derive from parent” does **not** apply to those rows.

Production default read/analytics excludes test.

No fake auth user.

---

## 18. Notification intent evolution

Reuse `user_notifications` + private outbox with metadata:

- notification_kind
- urgency: immediate/digest/in_app_only
- safety_class
- bundle_key
- business_expires_at
- test_context_id

Production outbox only consumes non-test business intent.

Synthetic delivery uses separate operator test adapter.

---

## 19. DailyBrief read model

No persistent DailyBrief table required. Server-side RPC/view composes current truth.

Minimum shape:

- generated_at / local_date / daypart
- urgent_actions
- exceptions
- active_infos
- burden_reducing_completed
- own_task_groups
- partner_summary
- carryovers + result_certainty
- waiting_checks
- reconciliation prompt
- schedule including all-day entries
- deep links

Waiting:

- future next-check: suppress ordinary incomplete nag
- check date due: waiting_checks
- hard deadline risk can be urgent while still waiting
- read never auto-resumes task

All-day display is included; timed conflict remains separate.

---

## 20. Migration phases — corrected binding order

This section replaces the older ambiguous “write Phase 3 / read Phase 4” interpretation.

### Phase 0 — docs only

No runtime change.

### Phase 1 — additive/evolution schema readiness

- ActorRef + new columns/tables
- direct test_context columns
- task completion CHECK replacement
- Request CHECK catalog verification + CHECK-valid compatibility helper path
- DailyBrief schedule CHECK extension + override table
- shopping extension
- Family Event/link/candidate schema
- Task→Google mirror / target-deletion ownership guard fields/state as needed
- orphan reconciliation/adoption guard representation as needed
- RLS/FK/index/checks
- compatibility helpers

No new semantic state enabled.

Rollback class R0.

### Phase 2 — deterministic backfill/reconciliation

- real member ActorRefs
- task assignment snapshots
- actual participants
- Request Attempts
- handover defaults
- task policy snapshots
- legacy Request↔Task/assignment-scope mismatch report
- CURRENT Google provider lifecycle reconciliation across:
  - `family_ops_calendar_mirrors` provider identity/queue/lease state
  - `family_ops_calendar_target_deletions` provider identity/delete-job/retry/lease/blocked state
  - `family_ops_calendar_orphaned_mirrors` provider identity/reason/observed state
- **50-table physical precondition audit**

Idempotent. No guessed performer/anyone/event/provider linkage. Orphan rows never imply a writable provider link.

Rollback class R0.

### Phase 3 — deploy canonical reader + command adapters inactive

For each aggregate deploy:

- canonical command path
- canonical read model
- compatibility projection/helper
- old endpoint adapter route readiness
- no first new-only semantic state yet

Test ActorRef/execution-context/side-effect sandbox foundation must exist before actual-household simulation.

Rollback class R1.

### Phase 4 — atomic aggregate activation

For one aggregate at a time:

1. reconciliation passes
2. old endpoint routes to canonical adapter
3. canonical reader + writer gate activate together
4. only then new-only semantic states are permitted

Aggregates include at least:

- Request
- task actual/reconciliation
- shopping
- DailyBrief
- Family Event/Google Authority

First new-only canonical state crosses P1.

P1 examples:

- checking/consulting/awaiting_confirmation
- anyone active claim
- multiple performers
- waiting
- mostly-done evidence
- Family Event authority state that legacy current-truth reader cannot represent

After P1 legacy current-truth read/write rollback prohibited.

### Phase 5 — legacy route retirement

- direct legacy request writer disabled
- legacy actual actor ceases canonical use
- old routine pushes disabled after DailyBrief cadence cutover
- old Task→Google path remains only for still Task-owned projections
- transferred Family Event provider IDs cannot be re-enqueued by Task bridge or executed by stale target-deletion job
- unresolved permission-loss orphan remains explicit audit state and cannot be silently adopted

Physical column/table cleanup is separate future review.

---

## 21. Backfill rules

### 21.1 ActorRefs

One real-user ActorRef per current household member, idempotently.

Existing production row is never converted to simulated identity.

### 21.2 Task assignment

legacy planned assignee non-null -> matching real ActorRef + person assignment + legacy snapshot source.

Null assignment is not guessed into anyone.

### 21.3 Actual participants

legacy actual actor -> matching participant.

Completed but actor-null -> no fake participant; explicit legacy unknown treatment.

### 21.4 Requests

Deterministic initial mapping:

- pending -> initial pending
- accepted -> accepted agreement
- completed -> accepted agreement + linked Task execution truth
- declined -> declined
- cancelled -> cancelled

Pre-cutover report detects:

- missing/invalid/duplicate linked task
- status vs linked Task contradiction
- lifecycle timestamp contradiction
- assignment_change_request_tasks scope mismatch
- any current row that cannot be represented without guessing

No inferred repair.

### 21.5 Task outcome

Legacy skipped reason is not guessed.

New writes distinguish at least could_not_do / not_needed_this_occurrence / expired_occurrence.

### 21.6 Google provider lifecycle reconciliation

Inventory every existing provider-lifecycle row in all three CURRENT tables.

For `family_ops_calendar_mirrors`, record at least:

- projection key
- kind
- task instance
- connection
- provider event ID
- provider ETag
- desired action
- sync/lease/retry/blocked state

For `family_ops_calendar_target_deletions`, record at least:

- calendar connection
- projection key
- provider event ID
- sync state including blocked/deleted
- attempts / next attempt
- lease token / lease expiry
- last error

For `family_ops_calendar_orphaned_mirrors`, record at least:

- calendar connection
- projection key
- provider event ID
- reason
- observed_at

Do not auto-create Family Events from mirror/deletion/orphan state. A deletion queue row is a provider mutation path until safely terminal/superseded; an orphan row is observation only and never writable ownership.

Explicit adoption to Family Event follows `08` §10 ownership-transfer protocol, including live lease blocking, stale DELETE prevention, orphan revalidation, provider ID/ETag preservation, and three-path provider-mutation overlap audit. Implementation/release gates are `07` WP-DD2 / WP-DD8 / WP-DD11.

### 21.7 Test data

Existing production data is not reclassified as test. Only explicitly created simulation state gets test context.

---

## 22. Index / constraint expectations

Detailed DDL review must cover at least:

- ActorRef kind/FK/uniqueness
- production/test ActorRef isolation
- active request attempt uniqueness
- Request legacy tuple CHECK-valid projection
- active anyone claim consistency
- participant uniqueness + compatibility-primary constraint during migration
- reconciliation item FK + test context
- shopping claim/revision consistency
- source/extraction/fact household isolation
- Event external link/provider identity uniqueness
- exactly-one **provider mutation owner/path** invariant across Task mirror bridge vs target-deletion DELETE bridge vs Family Event external-link writer
- unresolved matching orphan cannot establish writable ownership without fresh provider access/identity/ETag revalidation
- candidate source/target indexes
- RLS household isolation
- service-role-only sensitive mutation RPCs

---

## 23. No destructive shortcut

禁止:

- old Request rows一括削除
- completed history書換え
- recurrence history collapse
- legacy Request timestampをcanonical historyとして扱う
- Google provider identityをtitle/dateから再構築
- Task mirror / target-deletion DELETE / Family Event writerを同じprovider identityへ同時に有効化
- stale target-deletion queue rowの存在だけをDELETE権限として扱う
- permission-loss orphanをwritable Family Event linkへsilent昇格
- raw nursery image削除とconfirmed structured data削除を連動
- Google cacheをFamily Event truthとして直接流用
- simulated actorをreal spouse/operator IDへupdate
- P1後legacy current-truth reader/writer復活
- production dataをtestへ再分類
