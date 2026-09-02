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

The inventory must match case-insensitive `create table` declarations including optional `IF NOT EXISTS`; a pattern that only matches plain `create table public...` is not sufficient. The prior 46- and 48-table counts each missed live `IF NOT EXISTS` tables.

The corrected CURRENT application-owned table inventory is:

- **public: 27**
- **private: 23**
- **total: 50**

The four late tables that earlier counts missed are:

- `public.household_task_categories`
- `private.family_ops_calendar_mirrors`
- `private.family_ops_calendar_target_deletions`
- `private.family_ops_calendar_orphaned_mirrors`

The three private `family_ops_calendar_*` tables are one live provider-lifecycle subsystem, not dead residue:

- `family_ops_calendar_mirrors` is the durable Task/transport projection/outbox;
- `family_ops_calendar_target_deletions` is the durable old-target provider DELETE outbox with claim/lease/retry;
- `family_ops_calendar_orphaned_mirrors` records stable provider identities that can no longer be safely managed after calendar permission/eligibility loss.

### 2.1 Disposition legend

- `KEEP`: preserve current truth/transport responsibility.
- `EVOLVE`: reuse the table but extend/narrow semantics or add compatibility fields.
- `BRIDGE`: preserve as an explicit migration/interoperability/provider-write path with a bounded ownership role; it must not become a competing canonical household truth.
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

### 2.3 Private tables — 23/23

| # | Current table | Disposition | Binding treatment |
|---:|---|---|---|
| 1 | `private.google_connections` | KEEP | Credential binding/encryption unchanged. |
| 2 | `private.google_watch_channels` | KEEP | Watch overlap/verification unchanged. |
| 3 | `private.google_sync_state` | KEEP | Sync token truth unchanged. |
| 4 | `private.google_sync_jobs` | KEEP | Queue/lease/coalescing unchanged. |
| 5 | `private.google_event_staging` | KEEP | Full/incremental sync staging unchanged. |
| 6 | `private.google_write_operations` | KEEP | Provider create/update idempotency retained; test context hard-blocked. |
| 7 | `private.family_ops_calendar_mirrors` | BRIDGE | Bounded Task/transport → Google projection bridge. Never Family Event truth. Provider ownership rules are in §10. |
| 8 | `private.family_ops_calendar_target_deletions` | BRIDGE | Durable old-write-target provider DELETE queue. It is a provider mutation path and must participate in the exactly-one-provider-writer/transfer guard in §10. |
| 9 | `private.family_ops_calendar_orphaned_mirrors` | KEEP | Audit/observation of provider identities that became unmanageable after calendar permission/eligibility loss. It is not canonical Family Event truth and never proves a writable provider link by itself. |
| 10 | `private.webhook_inbox` | KEEP | LINE durable inbox/dedup retained. |
| 11 | `private.line_user_links` | KEEP | Real user LINE identity only. |
| 12 | `private.pending_actions` | EVOLVE | Reuse preview/confirm queue with revision/test/ActorRef-aware context. |
| 13 | `private.raw_inputs` | EVOLVE | Reuse for short-lived private raw input only; no durable third-party OCR transcript. |
| 14 | `private.household_invites` | OUT-OF-SCOPE | Existing membership setup retained. |
| 15 | `private.line_link_tokens` | OUT-OF-SCOPE | Existing link security retained. |
| 16 | `private.google_oauth_states` | KEEP | Existing replay-safe OAuth state retained. |
| 17 | `private.notification_outbox` | EVOLVE | Durable delivery/retry/quota reused; production-only. Synthetic test delivery never writes here. |
| 18 | `private.line_quota_state` | KEEP | Existing hard-cap accounting retained. |
| 19 | `private.line_quota_reservations` | KEEP | Existing atomic reservation retained. |
| 20 | `private.worker_run_receipts` | KEEP | Existing worker idempotency retained. |
| 21 | `private.jp_holidays` | KEEP | Holiday source drives non-workday morning brief. |
| 22 | `private.mutation_receipts` | EVOLVE | Preserve idempotency; distinguish authenticated operator from canonical ActorRef/test scope. |
| 23 | `private.scheduled_dispatch_receipts` | EVOLVE | Add DailyBrief kinds/dedup keys; legacy dispatch receipts remain historical. |

No CURRENT table may be omitted because it was created with `IF NOT EXISTS`, introduced after the original v6 snapshot, private/internal, or primarily transport-oriented.

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

## 10. CURRENT Google provider lifecycle → new Family Event Authority boundary

This section closes the active CURRENT provider lifecycle, which consists of:

- `private.family_ops_calendar_mirrors`: Task/transport upsert/delete bridge;
- `private.family_ops_calendar_target_deletions`: old write-target provider DELETE queue;
- `private.family_ops_calendar_orphaned_mirrors`: provider identities that became unmanageable after calendar permission/eligibility loss.

The first two can cause provider mutations. The orphan table is evidence/observation and does not grant write ownership.

### 10.1 Bounded roles after redesign

`family_ops_calendar_mirrors` remains a **BRIDGE for Task-owned calendar projections only**:

- transport daily projection (`送 P ｜ 迎 M`);
- explicitly calendar-visible standalone Task where product settings opt that Task into Google.

`family_ops_calendar_target_deletions` remains a **BRIDGE for deletion of an old Task-mirror write target only**. It may delete an event only while that provider identity remains owned by the Task/provider-transition lifecycle that created the deletion job.

`family_ops_calendar_orphaned_mirrors` remains **KEEP audit state**:

- it records a provider identity that Family Ops could no longer manage safely;
- it is not Family Event current truth;
- it is not evidence that the provider event still exists or is writable;
- it cannot be converted to a Family Event external link without restored provider access and fresh identity/ETag revalidation.

None of these tables is:

- Family Event household truth;
- Family Event field Authority;
- an alternate current-state source for a Family Event.

Family Events use the new Family Event + external-link/Authority path. Google cache remains provider observation.

### 10.2 Exactly-one-provider-mutation-owner invariant

For each `(calendar_connection_id, provider_event_id)` or deterministic not-yet-created provider identity, **at most one Family Ops provider-mutation owner/path may be active**.

The mutually exclusive provider mutation paths are:

1. Task mirror bridge (`family_ops_calendar_mirrors`) for Task-owned upsert/delete;
2. old-target deletion bridge (`family_ops_calendar_target_deletions`) for provider DELETE;
3. Family Event external-link writer.

The deletion bridge counts as a writer for this invariant even though its mutation is DELETE rather than PATCH/CREATE.

`family_ops_calendar_orphaned_mirrors` is not a writer, but an unresolved orphan record for the same identity is a transfer/cutover blocker until provider authority/identity is revalidated or the row is explicitly classified as historical-unmanageable.

No title/date matching decides ownership. The invariant is enforced at command/DB adapter level and included in reconciliation before Family Event P1.

### 10.3 Existing transport mirrors

Transport mirrors remain Task-owned and are not auto-converted to Family Events. They continue to use the stable transport projection key unless a later separately reviewed requirement changes transport presentation.

### 10.4 Existing special Task mirrors

Do **not** infer that every current `special` Task mirror is a Family Event.

Default migration treatment:

- existing Task mirror remains Task-owned bridge;
- no automatic conversion based on title/date/category;
- if the user/system later explicitly adopts that provider event into a Family Event, use §10.5.

This preserves current Google linkage without inventing Event truth.

### 10.5 Ownership transfer / adoption protocol

When an existing Task-mirrored provider event is explicitly adopted as a Family Event:

1. lock/identify the Task mirror by stable projection key and provider identity; no title search;
2. prevent new Task-trigger enqueue for that projection during transfer using a guard/ownership state;
3. if the Task mirror itself is `processing` with an unexpired lease, wait/retry after lease completion; never race the worker;
4. reconcile Task-mirror `pending/failed/blocked` state to a known provider observation or stop with an explicit anomaly; never silently discard it;
5. inspect `family_ops_calendar_target_deletions` for the same `(calendar_connection_id, projection_key, provider_event_id)`:
   - `processing` with a live lease blocks transfer until the worker finishes/fails/lease expires and is reconciled;
   - `pending/failed/blocked` must be explicitly superseded/cancelled by a forward migration/command **without deleting its audit history**, but only after a fresh provider observation proves the event still exists and the selected calendar is writable;
   - if the deletion already completed, the deleted provider identity cannot be adopted as a live external link; create/link a new valid provider event instead;
6. inspect `family_ops_calendar_orphaned_mirrors` for the same provider identity:
   - unresolved orphan state blocks adoption;
   - adoption is permitted only after Google access is restored and the exact provider event existence/identity/ETag is freshly revalidated, or after the user intentionally links a different eligible provider event;
   - never treat an orphan record alone as a writable link;
7. obtain authoritative `provider_event_id`, current ETag and owned-field external snapshot from fresh provider/cache state;
8. create `family_event_external_links` for the chosen Family Event using that exact provider identity/snapshot;
9. atomically mark the Task mirror as superseded/bridge-disabled and ensure any matching target-deletion job is terminal non-mutating/superseded before Family Event ownership activates;
10. only after the preceding ownership change may the Family Event writer issue provider mutations;
11. verify the exactly-one-provider-mutation-owner invariant after transfer.

The implementation may add explicit bridge ownership/superseded/cancelled-by-transfer states rather than overloading existing `sync_state`; exact column names are DDL-review detail. The invariant and transition order are mandatory.

### 10.6 Queue, permission-loss, and orphan reconciliation

Before Family Event aggregate P1, the reconciliation report must cover all three CURRENT provider-lifecycle tables.

For `family_ops_calendar_mirrors`:

- no ambiguous row may target the same provider identity as a Family Event writer;
- `processing` lease must be resolved/expired/reclaimed safely;
- `pending` / `failed` / `blocked` either complete under Task ownership or are explicitly superseded/transferred after provider reconciliation;
- `deleted` rows do not fabricate live external links.

For `family_ops_calendar_target_deletions`:

- inspect `pending / processing / failed / blocked / deleted` for every provider identity proposed for Family Event ownership;
- no pending/processing/failed deletion may survive transfer as an executable delete against the newly Family-Event-owned provider identity;
- processing lease is never cancelled underneath an active worker; resolve/reconcile first;
- blocked deletion caused by lost permission does not prove cleanup occurred and cannot be silently discarded;
- a deletion completed before transfer means the old provider event must not be adopted as live.

For `family_ops_calendar_orphaned_mirrors`:

- record is preserved as audit evidence;
- unresolved orphan for the target provider identity blocks ownership transfer unless access/identity is freshly revalidated;
- orphan rows are not auto-converted into Family Event links;
- provider event ID/ETag/existence is never guessed from the orphan row.

The report records unresolved rows and blocks the affected household/event cutover. Provider ID/ETag/linkage is never guessed.

### 10.7 Trigger/worker cutover and destructive-write guard

Task enqueue trigger remains active for Task-owned projections but must not enqueue a projection whose provider ownership has transferred to a Family Event.

The target-deletion claim/worker path must also enforce current ownership before destructive provider DELETE:

- a deletion job that has been superseded by an ownership transfer is not claimable/executable;
- if ownership changed after a job was queued, the worker/claim adapter revalidates provider ownership before DELETE and returns/records a non-mutating superseded result rather than deleting the event;
- no worker may rely only on stale queue-row existence as delete authorization.

Family Event writer never consumes either legacy bridge table as its canonical queue. It uses the Family Event external-link + existing Google write/idempotency machinery defined by the Authority design.

This prevents Task PATCH/DELETE, old-target DELETE, and Family Event mutation from racing on one provider identity.

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

- all three CURRENT provider-lifecycle tables inventoried/reconciled;
- no Task mirror / old-target deletion / Family Event provider-mutation overlap;
- transport mirror remains valid;
- explicit special-Task → Family Event adoption preserves provider event ID/ETag without title matching;
- pending/failed/processing/blocked Task mirror state reconciled before ownership transfer;
- pending/failed/processing/blocked target-deletion state reconciled or safely superseded before ownership transfer;
- completed target deletion cannot be adopted as a live provider link;
- orphaned provider identity never becomes Family Event ownership without restored access + fresh identity/ETag validation;
- transferred Task projection cannot be re-enqueued by Task trigger;
- superseded deletion job cannot later DELETE a Family-Event-owned provider event;
- exactly-one-provider-mutation-owner audit is zero-conflict before Family Event P1.

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
| CURRENT table inventory incomplete | §2, corrected to **50 = public 27/private 23** |
| `household_task_categories` omitted | §2.2 |
| active `family_ops_calendar_mirrors` omitted | §§2.3,10 |
| active `family_ops_calendar_target_deletions` omitted | §§2.3,10 |
| active `family_ops_calendar_orphaned_mirrors` omitted | §§2.3,10 |
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
| Google provider ownership omitted deletion/orphan lifecycle | §§10,14 |

---

## 17. Review / implementation gate

This PR remains **NO IMPLEMENTATION** until fresh independent review of the actual current PR head returns `GO`.

Required gate:

- BLOCKER 0
- HIGH 0
- Requirements contradiction 0
- **50/50 CURRENT table disposition accounted for (public 27/private 23)**
- task and Request physical CHECK compatibility executable
- Request read/write cutover atomic
- no hidden provider mutation overlap among Task mirror, target deletion queue, and Family Event writer
- orphaned provider identities cannot silently become writable Family Event links
- test identity/scope leakage closed
- schedule/shopping/all-day paths executable without product-truth invention
- Requirements Final-GO MEDIUM 3 remain PASS

If any BLOCKER/HIGH remains, do not merge PR #41, do not accept ADR 0013, and do not begin implementation.