# 08. CURRENT Main Physical Schema Alignment and Review Remediation

## 1. Purpose and normative scope

This document is the binding physical-alignment contract between the accepted Family Ops product/domain design and the actual CURRENT `main` schema/runtime.

- CURRENT `main`: `7729c93ee10db29b145592763886cfa5f9a019e0`
- Requirements Source of Truth: `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- ADR 0012: Accepted
- ADR 0013: Proposed until detailed-design independent review returns `GO`

This document does **not** create a second product-requirements layer. It fixes migration, compatibility, cutover, and CURRENT-runtime details that cannot safely be left to implementer invention.

Where this document conflicts with an older physical assumption in `02_DATA_MODEL_AND_MIGRATION.md`, `04_LINE_PWA_DAILY_UX_AND_NOTIFICATIONS.md`, `05_GOOGLE_IMAGE_AI_AUTHORITY_PRIVACY.md`, `06_TEST_MODE_CONCURRENCY_OBSERVABILITY.md`, or `07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`, this document governs the physical/cutover detail. Requirements + ADR 0013 remain authoritative for product/domain meaning.

No code, migration, Supabase runtime, Edge Function, LINE runtime, Google Calendar runtime, Vercel, or production data is changed by this documentation PR.

---

## 2. Fresh CURRENT main physical inventory

Fresh-read CURRENT migrations include the later `20260821` through `20260825` chain and **78 migration files**.

A prior review/count incorrectly treated only plain `create table` statements as inventory and missed `create table if not exists` statements introduced by `20260822000001_calendar_projection_domain.sql`.

CURRENT application-owned table inventory relevant to this program is therefore:

- **public: 27**
- **private: 21**
- **total: 48**

The two tables that must not be omitted are:

- `public.household_task_categories`
- `private.family_ops_calendar_mirrors`

The latter is active infrastructure: later migrations evolve it into the durable Task → Google projection/outbox path and install triggers/workers around it. It is not dead documentation-era residue.

### 2.1 Disposition legend

- `KEEP`: preserve current truth/transport responsibility.
- `EVOLVE`: reuse the table but extend/narrow semantics or add compatibility fields.
- `BRIDGE`: preserve as an explicit migration/interoperability path with a bounded ownership role; it must not become a competing canonical truth.
- `SUPERSEDE`: keep for history/compatibility while canonical semantics move elsewhere; no independent new truth after cutover.
- `OUT-OF-SCOPE`: retained and not materially changed by this program.

### 2.2 Public tables — 27/27

| # | Current table | Disposition | Binding treatment |
|---:|---|---|---|
| 1 | `public.households` | KEEP | Household boundary remains canonical. |
| 2 | `public.profiles` | KEEP | Display profile only; no simulated identity rows. |
| 3 | `public.household_members` | KEEP | Real membership only; never create fake simulated spouse/auth membership. |
| 4 | `public.household_task_categories` | EVOLVE | Reuse the household task/category taxonomy. It classifies Task/household work presentation only; it does not become Event Authority or assignment truth. New task/event UI may map to this taxonomy, but Family Event type/school context remains separate domain data. |
| 5 | `public.task_definitions` | EVOLVE | Expectation/carryover/duplicate-sensitivity/early-completion defaults. |
| 6 | `public.task_subtask_definitions` | KEEP | Existing definition relation remains. |
| 7 | `public.recurrence_rules` | EVOLVE | Preserve effective dating/versioning; extend assignment result including `anyone`. |
| 8 | `public.task_instances` | EVOLVE | Assignment/claim/waiting/outcome/revision/test context + ActorRef compatibility; existing completion CHECKs replaced in Phase 1. |
| 9 | `public.task_subtask_instances` | EVOLVE | Canonical actor/test semantics added where needed; real-user `completed_by` becomes compatibility-only. |
| 10 | `public.task_events` | EVOLVE | Append-only audit retained; ActorRef/test-compatible actor identity. |
| 11 | `public.requests` | EVOLVE | Logical Request/provenance retained; Request Attempt owns negotiation; linked Task owns accepted execution; legacy lifecycle columns become a strict compatibility projection. |
| 12 | `public.handovers` | EVOLVE | Extend into share/handover information semantics with direct test context + ActorRef author. |
| 13 | `public.handover_reads` | EVOLVE | Real-user compatibility receipt; canonical acknowledgement must support ActorRef/test context. |
| 14 | `public.shopping_items` | EVOLVE | Separate shopping aggregate with assignment/claim/participant/duplicate-safety/revision/test context. |
| 15 | `public.user_notifications` | EVOLVE | In-app record reused; new notification intent/policy metadata. |
| 16 | `public.notification_preferences` | EVOLVE | Map legacy routine-specific toggles to morning/evening/exception policy. |
| 17 | `public.household_routine_schedules` | EVOLVE | Add DailyBrief schedule kinds; legacy nine kinds become compatibility rows disabled/suppressed after cutover. |
| 18 | `public.routine_checkin_sessions` | SUPERSEDE | Preserve history/compatibility; new reconciliation sessions own group evidence. |
| 19 | `public.routine_checkin_session_items` | SUPERSEDE | Preserve history/compatibility; no dual reconciliation truth. |
| 20 | `public.evening_routine_preferences` | EVOLVE | Preserve household routine configuration as rule/materialization input; do not silently delete. |
| 21 | `public.calendar_connections` | KEEP | Provider connection/write-target handle reused. |
| 22 | `public.calendar_events_cache` | KEEP | Canonical provider observation only, not household Event truth. |
| 23 | `public.calendar_event_occurrences` | KEEP | Provider occurrence projection reused; all-day rows included in display but excluded from timed conflict logic. |
| 24 | `public.calendar_occurrence_busy_members` | KEEP | Timed conflict attribution continues. |
| 25 | `public.calendar_busy_classifications` | KEEP | Existing manual busy classification reused. |
| 26 | `public.calendar_busy_classification_members` | KEEP | Existing normalized membership reused. |
| 27 | `public.assignment_change_request_tasks` | SUPERSEDE | Existing assignment-change scope mapping is migration/audit input only after Request/Attempt cutover; cannot remain an independent assignment-negotiation truth. |

### 2.3 Private tables — 21/21

| # | Current table | Disposition | Binding treatment |
|---:|---|---|---|
| 1 | `private.google_connections` | KEEP | Credential binding/encryption unchanged. |
| 2 | `private.google_watch_channels` | KEEP | Watch overlap/verification unchanged. |
| 3 | `private.google_sync_state` | KEEP | Sync token truth unchanged. |
| 4 | `private.google_sync_jobs` | KEEP | Queue/lease/coalescing unchanged. |
| 5 | `private.google_event_staging` | KEEP | Full/incremental sync staging unchanged. |
| 6 | `private.google_write_operations` | KEEP | Provider create/update idempotency retained; test context hard-blocked. |
| 7 | `private.family_ops_calendar_mirrors` | BRIDGE | Remains the bounded Task/transport → Google projection bridge. It must never become Family Event household truth or a second Family Event writer. Ownership-transfer rules are in §10. |
| 8 | `private.webhook_inbox` | KEEP | LINE durable inbox/dedup retained. |
| 9 | `private.line_user_links` | KEEP | Real user LINE identity only. |
| 10 | `private.pending_actions` | EVOLVE | Reuse preview/confirm queue with revision/test/ActorRef-aware context. |
| 11 | `private.raw_inputs` | EVOLVE | Reuse for short-lived private raw input only; no durable third-party OCR transcript. |
| 12 | `private.household_invites` | OUT-OF-SCOPE | Existing membership setup retained. |
| 13 | `private.line_link_tokens` | OUT-OF-SCOPE | Existing link security retained. |
| 14 | `private.google_oauth_states` | KEEP | Existing replay-safe OAuth state retained. |
| 15 | `private.notification_outbox` | EVOLVE | Durable delivery/retry/quota reused; production-only. Synthetic test delivery never writes here. |
| 16 | `private.line_quota_state` | KEEP | Existing hard-cap accounting retained. |
| 17 | `private.line_quota_reservations` | KEEP | Existing atomic reservation retained. |
| 18 | `private.worker_run_receipts` | KEEP | Existing worker idempotency retained. |
| 19 | `private.jp_holidays` | KEEP | Holiday source drives non-workday morning brief. |
| 20 | `private.mutation_receipts` | EVOLVE | Preserve idempotency; distinguish authenticated operator from canonical ActorRef/test scope. |
| 21 | `private.scheduled_dispatch_receipts` | EVOLVE | Add DailyBrief kinds/dedup keys; legacy dispatch receipts remain historical. |

No CURRENT table may be omitted because it was created with `IF NOT EXISTS`, introduced after the original v6 snapshot, or considered “internal”.

---

## 3. Task completion CHECK compatibility — BLOCKER closure

CURRENT `task_instances` physical constraints require:

- subtask-mode parent `actual_completed_by_id IS NULL`;
- whole + completed `actual_completed_by_id IS NOT NULL`.

The participant-truth design therefore cannot start writing new completion semantics until those CHECKs are replaced by a forward migration.

### 3.1 Phase 1 mandatory replacement

The first task-completion migration must:

1. inspect **actual production catalog constraint names/definitions**;
2. replace the two completion-mode CHECKs with explicitly named constraints compatible with ActorRef participants/test context;
3. never rewrite an applied migration;
4. never drop `actual_completed_by_id` in this program;
5. retain completed/completed_at integrity.

Binding semantics:

- `subtasks`: parent legacy mirror stays null; canonical performer truth is subtask/participant ActorRef data.
- production `whole + completed`: canonical participant(s) required and exactly one technical compatibility-primary real participant mirrored to `actual_completed_by_id` while legacy readers exist.
- test/simulated `whole + completed`: canonical ActorRef participant(s) required; legacy real-user mirror may be null.

The phrase “while legacy readers exist” is a rollout condition, not a PostgreSQL CHECK predicate. During the compatibility phase the deployed physical constraint is unconditional for production whole completions; a later separately reviewed cleanup migration may relax/remove that compatibility requirement after all old readers are retired.

### 3.2 Compatibility-primary participant

This field has **zero product meaning**.

Canonical participant representation includes:

- `actor_ref_id`
- `recorded_by_actor_ref_id`
- `test_context_id`
- `compatibility_primary boolean not null default false`

Rules:

- production whole completion: exactly one active real participant is compatibility-primary until old readers retire;
- choose recorder if recorder is an explicitly declared performer, otherwise first explicitly declared performer in confirmed command payload;
- correction may change it only atomically with participant/audit correction;
- no UI/history/analytics may describe it as a primary contributor or infer greater contribution;
- test/simulated completion has no real-user compatibility-primary mirror requirement;
- subtask parent never uses legacy parent actor as participant truth.

---

## 4. Request Attempt → legacy Request physical projection — HIGH closure

CURRENT `requests` has both:

1. `status NOT NULL` with allowed values `pending | accepted | declined | completed | cancelled`;
2. a second CHECK that requires `status` and `accepted_at / declined_at / completed_at / cancelled_at` to be mutually consistent.

Therefore **status-only projection is invalid**. The compatibility projection must update the five legacy lifecycle fields atomically.

Canonical Request/Attempt remains the only new truth. Legacy fields exist solely to keep CURRENT physical constraints/readers valid until cutover.

### 4.1 Pre-agreement compatibility projection

For a logical Request that has **not yet established an accepted agreement**, project the current canonical attempt as follows:

| Canonical attempt state | legacy `status` | `accepted_at` | `declined_at` | `cancelled_at` | `completed_at` | Meaning |
|---|---|---|---|---|---|---|
| `pending` | `pending` | null | null | null | null | old-compatible pending |
| `checking` | `pending` | null | null | null | null | compatibility only; canonical UI says 確認中 |
| `consulting` | `pending` | null | null | null | null | compatibility only; canonical UI says 相談中 |
| `awaiting_confirmation` | `pending` | null | null | null | null | compatibility only; canonical UI shows terms confirmation |
| `accepted` | `accepted` | canonical acceptance timestamp | null | null | null | agreement established; linked Task becomes execution truth |
| `declined` | `declined` | null | canonical decline timestamp | null | null | canonical terminal attempt |
| `expired` | `cancelled` | null | null | canonical expiry timestamp **as compatibility-only cancelled_at** | null | canonical history remains `expired`; legacy field must never be shown as user-cancel truth after cutover |
| `cancelled` | `cancelled` | null | null | canonical cancel timestamp | null | canonical cancelled attempt |

If a pre-agreement reproposal creates a new active attempt after a prior terminal attempt, the legacy lifecycle tuple may be reprojected to the new current compatibility state, including clearing the old legacy terminal timestamp. The canonical prior attempt remains immutable in `request_attempts`; clearing a compatibility timestamp does **not** erase canonical history.

### 4.2 Post-agreement multi-attempt composition

Once any initial/reproposal attempt has established an accepted agreement, the logical Request has an accepted execution relationship with its linked Task.

From that point onward:

- legacy `requests.status = 'accepted'`;
- legacy `accepted_at` remains the timestamp of the established agreement represented by the compatibility row;
- legacy `declined_at/cancelled_at/completed_at` remain null for **new-runtime** rows;
- an active or terminal `change` / `cancel` attempt is **not projected into the legacy lifecycle tuple**;
- the pending change/cancel negotiation exists only in canonical `request_attempts` and canonical readers;
- accepted change updates Task/assignment atomically but legacy Request remains `accepted`;
- declined/expired/cancelled change attempt leaves legacy Request `accepted`;
- accepted cancel attempt closes/cancels the canonical relationship/linked work according to the command contract, but the compatibility legacy Request still remains `accepted` because CURRENT CHECK cannot represent “accepted in the past, later mutually cancelled” without destroying `accepted_at` meaning.

This is intentional: after semantic cutover no user-visible reader may treat legacy lifecycle fields as current Request truth.

Historical pre-cutover `requests.status='completed'` rows are preserved as-is. Backfill represents them canonically as accepted agreement + linked Task execution result. New runtime does not independently set Request `completed` when the Task completes.

### 4.3 Existing Request CHECK strategy

Phase 1 must inspect the real production Request CHECKs as explicitly as it inspects the task completion CHECKs.

Chosen strategy:

- **keep the existing legacy status/timestamp CHECK semantics during compatibility**;
- implement one server-owned compatibility projection helper/transaction that writes `status + accepted_at + declined_at + cancelled_at + completed_at` as one tuple according to §§4.1–4.2;
- do not add `checking/consulting/awaiting_confirmation/expired` as legacy `status` values;
- do not let arbitrary new command code update only one legacy lifecycle field;
- if actual production constraints differ from CURRENT main at implementation time, stop and re-review before migration.

This avoids a second semantic lifecycle while preserving executable physical compatibility.

### 4.4 Direct readers/writers that cut over atomically

At minimum:

- `apps/web/src/features/requests/Requests.tsx`
- `apps/web/src/features/today/useTodayData.ts`
- `accept-request`
- `decline-request`
- `cancel-request`
- assignment-change accept/create paths
- corresponding `server_tx_*` request functions
- LINE-native request/postback path from `20260822000009_line_native_requests.sql`
- assignment-change implementation from `20260821000001_assignment_change_requests.sql`

A canonical `checking/consulting/awaiting_confirmation` state may never exist while an old user-visible reader for that household can still render legacy `pending` as unrestricted `引き受ける / 断る`.

---

## 5. Aggregate-level atomic semantic cutover

The old phrase “Phase 3 write, Phase 4 read” is superseded.

Binding phase meaning:

- **Phase 1:** additive schema + CHECK/FK/index readiness.
- **Phase 2:** deterministic backfill + reconciliation.
- **Phase 3:** deploy canonical commands **and canonical readers inactive** behind aggregate gate; no new semantic state yet.
- **Phase 4:** atomically activate canonical **read + write** for one aggregate after both are ready.
- **Phase 5:** retire direct legacy reader/writer routes; physical cleanup remains separately reviewed.

For each aggregate (`request`, `task_actual`, `shopping`, `daily_brief`, `family_event`):

1. schema + canonical command + canonical reader deployed;
2. reconciliation passes;
3. old public endpoint routes through canonical adapter;
4. read and write gate flips together for household/release;
5. only then first new-only state is allowed.

There is no supported interval where checking/consulting/anyone claim/multiple performer/waiting/mostly-done can be written while the corresponding old current-truth reader remains active.

### R0 / R1 / P1

- `R0`: additive/backfill only; old runtime can still be used.
- `R1`: canonical adapter+reader deployed inactive; activation can be cancelled before new-only state.
- `P1`: first new-only semantic state exists.

After P1:

- no legacy current-truth read rollback;
- no legacy semantic writer rollback;
- incident response = mutation pause if needed + canonical/degraded projection + forward-fix;
- feature flag is never a truth rollback switch;
- P1 crossing is operationally recorded per aggregate/household release.

---

## 6. ActorRef and direct test scoping

The common `domain_actor_refs` model remains binding:

- `real_user`
- `simulated_member`
- `system`

Operator/auth principal and domain actor are separate concepts. Simulated mama/papa must never be persisted by substituting the authenticated operator's user ID.

Direct `test_context_id` is required on the canonical test-capable business rows, including:

- `task_instances`
- `task_actual_participants`
- `task_reconciliation_sessions`
- `task_reconciliation_session_items`
- `handovers`
- `requests`
- `request_attempts`
- `request_attempt_confirmations`
- `shopping_items`
- shopping claim/participant rows
- `family_events`
- change candidates / source documents created in simulation

Parent-derived test scope is additional validation, not a replacement for this leakage discriminator.

Production-default reads must exclude test state for:

- DailyBrief/Today
- scheduled dispatch
- Requests
- History/analytics
- handover/share
- shopping
- event/prep
- recurrence/materialization inputs
- notification policy/outbox

Side effects fail closed:

- production notification outbox cannot consume test business state;
- Google write rejects test/simulated context;
- real spouse consent/ack cannot be manufactured by simulation;
- synthetic LINE uses an operator-only test adapter, not production outbox.

One-user test cannot begin before ActorRef resolution, direct test scope, server-derived execution context, and side-effect guards exist.

---

## 7. Shopping remains a first-class aggregate

Do not convert `shopping_items` into Task merely to reuse task machinery.

Canonical shopping adds:

- `assignment_mode = person | unassigned | anyone`
- `assignee_actor_ref_id`
- `active_claimant_actor_ref_id`
- `claimed_at`
- `revision`
- `duplicate_sensitivity`
- direct `test_context_id`
- `shopping_actual_participants` with performer/recorder ActorRef and action kind

CURRENT `assignee_id` is production real-user compatibility mirror only. CURRENT `status='assigned'` is normalized as procurement state + responsibility in canonical read; it does not remain an independent second assignment truth.

`牛乳を買う / 誰でもOK` flow:

1. both see it;
2. `自分がやる` acquires claim; assignment mode remains anyone;
3. partner sees claimant;
4. claim can be released/taken over with revision safety;
5. order/purchase completion records participant and clears active claim atomically;
6. duplicate-sensitive neutral `対応済み` can notify partner when behavior must change.

If completion is undone/corrected to actionable, emit revision-aware neutral correction when partner behavior should change, e.g. `牛乳の買い物は未対応に戻りました` / medication-safe wording `朝の薬は未対応として確認し直してください`.

No praise/blame wording.

---

## 8. DailyBrief schedule persistence

CURRENT `household_routine_schedules.schedule_kind` has a fixed nine-kind CHECK.

Phase 1 evolves it to include at least:

- `weekday_morning_brief` → default 06:30
- `nonworkday_morning_brief` → default 09:00
- `evening_brief` → default 20:30

The existing `weekday is null` constraint is compatible because the kind itself distinguishes weekday/nonworkday.

Add date-specific override persistence, conceptually `household_routine_schedule_overrides`:

- household_id
- local_date
- brief kind
- enabled/skip
- optional local_time
- revision/update provenance
- unique household/date/kind

Explicitly evolve together:

- `RoutineSchedule.tsx`
- update-routine-schedule Edge/RPC
- `notification_preferences`
- `household_routine_schedules`
- `scheduled_dispatch_receipts`
- current routine dispatcher

After DailyBrief cadence cutover, legacy checklist/check-in rows may remain physically but cannot continue generating normal-day pushes that violate the two-anchor UX.

---

## 9. All-day display versus timed conflict

Keep these as separate concerns.

### Display

Relevant all-day Family Events and Google occurrences are visible in DailyBrief/PWA schedule.

- use `all_day_events[]` or typed schedule entries;
- never invent a fake 00:00 time;
- school events such as 運動会 / 遠足 / 食育 remain visible.

### Conflict

All-day occurrences remain excluded from person-specific timed busy/assignment conflict under current requirements.

Legacy reads that use `all_day_start is null` may continue serving timed conflict only. The DailyBrief display query must never reuse that predicate for visibility.

Mandatory scenarios:

1. nursery image → all-day Family Event → relevant morning brief visible;
2. Google all-day event → DailyBrief visible;
3. same event → no false timed assignment conflict.

---

## 10. CURRENT `family_ops_calendar_mirrors` → new Google Authority boundary

This section closes the previously omitted active Task → Google writer path.

CURRENT `private.family_ops_calendar_mirrors` is a durable projection/outbox with:

- stable projection key;
- Task/transport ownership inputs;
- desired upsert/delete;
- pending/processing/synced/failed/deleted state;
- provider event ID + ETag;
- lease/retry worker;
- Task mutation trigger enqueue;
- reconciliation when calendar write target changes.

It cannot be ignored when introducing Family Event Authority.

### 10.1 Bounded role after redesign

`family_ops_calendar_mirrors` remains a **BRIDGE for Task-owned calendar projections only**:

- transport daily projection (`送 P ｜ 迎 M`);
- an explicitly calendar-visible standalone Task where product settings still opt that Task into Google.

It is **not**:

- Family Event household truth;
- Family Event external-follow state;
- Family Event field Authority;
- a writer for a Google event once that provider event is owned by `family_event_external_links`.

Family Events use the new Family Event + external-link/Authority path. Google cache remains provider observation.

### 10.2 Exactly-one-writer invariant

For each `(calendar_connection_id, provider_event_id)` or deterministic not-yet-created provider identity, exactly one Family Ops writer-owner may be active:

- Task mirror bridge, **or**
- Family Event external-link writer,
- never both.

The invariant is enforced at command/DB adapter level and audited before cutover. No title/date matching decides ownership.

### 10.3 Existing transport mirrors

Transport mirrors remain in the Task bridge and are not auto-converted to Family Events. They continue to use the stable transport projection key unless a later separately reviewed requirement changes transport presentation.

### 10.4 Existing special Task mirrors

Do **not** infer that every current `special` Task mirror is a Family Event.

Default migration treatment:

- existing Task mirror remains Task-owned bridge;
- no automatic conversion based on title/date/category;
- if the user/system later explicitly adopts that provider event into a Family Event, use the ownership-transfer protocol below.

This preserves current Google linkage without inventing Event truth.

### 10.5 Ownership transfer / adoption protocol

When an existing Task-mirrored provider event is explicitly adopted as a Family Event:

1. lock/identify the mirror by stable projection key and provider identity; no title search;
2. prevent new Task-trigger enqueue for that projection during transfer (guard/ownership state);
3. if mirror is `processing` with an unexpired lease, wait/retry transfer after lease completion; never race the worker;
4. reconcile `pending/failed` mirror state to a known provider observation before transfer, or stop with an explicit migration/repair anomaly; never silently discard;
5. obtain authoritative `provider_event_id`, current ETag and owned-field external snapshot from the mirror/provider cache;
6. create `family_event_external_links` for the chosen Family Event using that exact provider identity/snapshot;
7. atomically mark the Task mirror as superseded/bridge-disabled for that provider identity and disable future Task enqueue for the transferred projection;
8. only after that ownership change may the Family Event writer issue future Google writes;
9. verify exactly-one-writer invariant after transfer.

The implementation may add a bridge ownership/superseded field/state rather than overloading `sync_state`; exact column naming is DDL-review detail. The state transition itself is mandatory.

### 10.6 Failed/pending queue reconciliation

Before Family Event aggregate P1:

- no ambiguous mirror row may target the same provider event as a Family Event writer;
- `processing` lease must be resolved/expired and reclaimed safely;
- `pending` / `failed` rows either complete under Task ownership or are explicitly transferred after provider reconciliation;
- `deleted` rows with no live provider event are not fabricated into external links;
- provider ID/ETag/linkage is never guessed;
- reconciliation report records unresolved rows and blocks affected household/event cutover.

### 10.7 Trigger/worker cutover

Task enqueue trigger remains active for Task-owned projections.

It must be changed/guarded so it does **not** enqueue a projection whose provider ownership has been transferred to a Family Event.

Family Event writer never consumes `family_ops_calendar_mirrors` as its canonical queue. It uses the Family Event external-link + existing Google write/idempotency machinery defined by the Authority design.

This prevents double Google writes while preserving the proven existing transport/task mirror implementation.

---

## 11. Task waiting and outcome mapping

Task waiting remains orthogonal current truth:

- `attention_state = active | waiting`
- `waiting_note`
- `next_check_at`
- original `due_at` preserved
- revision + audit

Waiting with a future check suppresses normal nag; next-check due resurfaces without auto-resume; hard deadline risk may surface while still waiting.

Outcome mapping:

| User meaning | Canonical current representation |
|---|---|
| 未入力 / 結果不明 | no terminal outcome; certainty remains unknown |
| できなかった | `status=skipped`, `outcome_reason=could_not_do` |
| 今回不要 | `status=skipped`, `outcome_reason=not_needed_this_occurrence` |
| occurrence expired | `status=skipped`, `outcome_reason=expired_occurrence` |
| 中止 | `status=cancelled`, cancellation reason/current field as defined by task schema |
| 再予定 | remains operationally open; reschedule mutation/audit stores prior schedule; no fake skip |

Legacy skipped reason is never guessed.

---

## 12. Consultation confirmation

For terms revisions:

1. participant explicitly proposing exact terms is atomically confirmed for that revision;
2. other required participant must confirm same revision;
3. AI/system summary alone implies **zero** confirmations;
4. edit increments terms revision and invalidates prior confirmations;
5. one-sided confirmation never changes formal assignment.

---

## 13. Legacy Request/backfill reconciliation gate

Before Request semantic cutover, repeatable read-only reconciliation must include:

- accepted/completed Request missing linked Task;
- duplicate/invalid linked Task relation;
- Request terminal state vs linked Task mismatch;
- `assignment_change_request_tasks` missing/extra/inconsistent scope rows;
- deterministically checkable lifecycle timestamp inconsistency;
- historical completed Request whose linked Task is not completed;
- accepted Request whose Task is contradictory terminal state;
- legacy lifecycle tuple failing CURRENT `requests` CHECK expectations;
- post-backfill canonical Request/Attempt projection not reproducible without guessing.

No inferred Task creation/completion/repair. Unresolved anomaly blocks affected household cutover unless explicitly classified legacy-unknown with reviewed treatment.

---

## 14. Binding implementation acceptance amendments

These requirements are mandatory even if an older `07` work-package line omitted them.

### Request cutover

Acceptance must prove:

- every new-runtime legacy Request tuple satisfies CURRENT status/timestamp CHECK;
- `checking/consulting/awaiting_confirmation` canonical states do not expose old accept/decline UI;
- accepted Request + pending change attempt keeps legacy tuple `accepted + accepted_at` while canonical reader shows the pending change;
- accepted Request + accepted/declined/expired/cancelled change/cancel attempt never causes a legacy CHECK failure;
- historical `completed` rows remain preserved/backfilled without guessed execution truth.

### Shopping package

A dedicated implementation package/subpackage must cover:

- shopping schema evolution;
- anyone claim/release/takeover;
- participants/recorder;
- revision/concurrency;
- test isolation;
- duplicate-sensitive completion + neutral undo correction;
- atomic read/write cutover.

### DailyBrief schedule package

Acceptance must cover:

- 06:30 / 09:00 / 20:30 persistence;
- one-day time override;
- one-day skip/disable override;
- legacy nine-kind push suppression after cutover;
- dispatcher receipt/dedup behavior.

### All-day package

Acceptance must include all three §9 scenarios.

### Google Authority package

Acceptance must include:

- existing Task mirror inventory/reconciliation;
- no Task mirror / Family Event double writer;
- transport mirror remains valid;
- explicit special-Task → Family Event adoption preserves provider event ID/ETag without title matching;
- pending/failed/processing mirror state safely reconciled before ownership transfer;
- transferred mirror cannot be re-enqueued by Task trigger.

---

## 15. Mandatory production-read/test leakage audit

Before one-user test on an actual household, verify zero test leakage into:

- Today/DailyBrief ordinary read;
- 06:30/09:00/20:30 production dispatch;
- History/analytics;
- Requests ordinary view;
- shopping ordinary view;
- handover/share ordinary view;
- recurrence/materialization production work;
- notification outbox;
- Google writes.

Any leak is a release blocker.

---

## 16. Closure matrix

| Review finding | Binding closure |
|---|---|
| task completion legacy CHECK blocker | §3 |
| Request new states lacked physical legacy projection | §4, including timestamps + multi-attempt composition |
| write/read phase contradiction | §5 |
| simulated/test state leakage | §6 + §15 |
| CURRENT table inventory incomplete | §2, corrected to 48 = public 27/private 21 |
| `household_task_categories` omitted | §2.2 |
| active `family_ops_calendar_mirrors` omitted | §§2.3,10 |
| shopping disconnected | §7 |
| DailyBrief schedule persistence missing | §8 |
| all-day display hidden by conflict filter | §9 |
| outcome_reason storage | §11 |
| compatibility-primary undefined | §3.2 |
| consulting proposer confirmation undefined | §12 |
| Request mismatch audit incomplete | §13 |
| one-user sandbox order/read leak | §§6,15 |
| duplicate-sensitive undo correction | §7 |
| work-package gaps for shopping/all-day/override | §14 |

---

## 17. Review / implementation gate

This PR remains **NO IMPLEMENTATION** until fresh independent review of the actual current PR head returns `GO`.

Required gate:

- BLOCKER 0
- HIGH 0
- Requirements contradiction 0
- 48/48 CURRENT table disposition accounted for
- task and Request physical CHECK compatibility executable
- Request read/write cutover atomic
- no hidden Task→Google / Family Event double writer
- test identity/scope leakage closed
- schedule/shopping/all-day paths executable without product-truth invention
- Requirements Final-GO MEDIUM 3 remain PASS

If any BLOCKER/HIGH remains, do not merge PR #41, do not accept ADR 0013, and do not begin implementation.