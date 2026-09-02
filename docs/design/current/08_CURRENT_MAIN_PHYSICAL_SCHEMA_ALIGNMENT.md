# 08. CURRENT Main Physical Schema Alignment and Review Remediation

## 1. Purpose and normative scope

This document closes the gap between the conceptual detailed design in `01`–`07` and the **actual CURRENT `main` physical schema/runtime**.

- CURRENT `main`: `7729c93ee10db29b145592763886cfa5f9a019e0`
- PR #41 branch before this remediation: `02fe5d956655cd0fc964c70de5dc4f84832d7d31`
- Requirements Source of Truth remains `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`.
- ADR 0012 remains Accepted.
- ADR 0013 remains Proposed until this detailed-design package receives independent `GO` and is merged.

This is **not a new product requirements layer**. It is the normative physical-alignment layer for CURRENT main.

Where this document explicitly amends a CURRENT-main physical assumption in `02_DATA_MODEL_AND_MIGRATION.md`, `04_LINE_PWA_DAILY_UX_AND_NOTIFICATIONS.md`, `05_GOOGLE_IMAGE_AI_AUTHORITY_PRIVACY.md`, `06_TEST_MODE_CONCURRENCY_OBSERVABILITY.md`, or `07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`, this document governs that physical constraint/cutover detail. Product behavior and Authority/truth ownership remain governed by Requirements + ADR 0013 + `01`–`07`.

The reason for a dedicated physical-alignment section is to prevent implementation from silently following an older v6-era table snapshot while keeping the reviewed conceptual design readable.

No code, migration, Supabase runtime, Edge Function, LINE runtime, Google Calendar runtime, Vercel, or production data is changed by this PR.

## 2. Fresh CURRENT main inventory

Fresh read of `supabase/migrations` at CURRENT main shows **78 migration files**. The resulting application-owned table inventory relevant to this design is **46 tables: public 26 / private 20**.

Important source migrations include:

- `20260819000002_core_household.sql`
- `20260819000003_tasks_recurrence.sql`
- `20260819000004_notifications_routine.sql`
- `20260819000005_calendar.sql`
- `20260819000006_private_queues_tokens.sql`
- `20260821000001_assignment_change_requests.sql`
- later migrations through `20260825000001_garbage_routines_and_cold_medicine_cleanup.sql`

### 2.1 Disposition legend

- `KEEP`: current table remains the same domain/transport truth; only ordinary compatible maintenance expected.
- `EVOLVE`: reuse the table but add columns/constraints/read adapters or narrow old semantics.
- `SUPERSEDE`: retain rows for history/compatibility, but new canonical semantics move elsewhere; no new independent truth may be created after cutover.
- `OUT-OF-SCOPE`: retained and not materially changed by this program.

### 2.2 Public tables — 26/26 disposition

| # | Current table | Disposition | Detailed-design treatment |
|---:|---|---|---|
| 1 | `public.households` | KEEP | Household boundary remains canonical. |
| 2 | `public.profiles` | KEEP | Display profile only; no simulated identity rows. |
| 3 | `public.household_members` | KEEP | **Real membership only.** Never create fake simulated spouse/auth membership. |
| 4 | `public.task_definitions` | EVOLVE | Add/snapshot expectation, carryover, duplicate sensitivity, early-completion defaults as needed. |
| 5 | `public.task_subtask_definitions` | KEEP | Existing definition relation remains. |
| 6 | `public.recurrence_rules` | EVOLVE | Preserve effective dating/versioning; extend assignment result semantics including `anyone`. |
| 7 | `public.task_instances` | EVOLVE | Assignment/claim/attention/waiting/outcome/revision/test context + ActorRef mirrors; existing completion CHECKs must be replaced in Phase 1. |
| 8 | `public.task_subtask_instances` | EVOLVE | Real-user `completed_by` becomes compatibility mirror; canonical actor reference/test scope added for new writes where needed. |
| 9 | `public.task_events` | EVOLVE | Continue append-only audit; add ActorRef/test context compatibility so simulated actors are not stored as operator user. |
| 10 | `public.requests` | EVOLVE | Keep logical request/provenance identity; attempt owns negotiation; linked Task owns accepted execution. Legacy `status` becomes compatibility projection only. |
| 11 | `public.handovers` | EVOLVE | Extend into share/handover information semantics; add direct test context + canonical author ActorRef. |
| 12 | `public.handover_reads` | EVOLVE | Keep real-user compatibility receipt; canonical acknowledgement actor semantics must support test context without fake membership. |
| 13 | `public.shopping_items` | EVOLVE | Remain a separate shopping aggregate; add assignment mode/claim/participant/duplicate sensitivity/revision/test context instead of converting shopping into Task. |
| 14 | `public.user_notifications` | EVOLVE | Keep in-app record; new notification intent/policy metadata. Production rows only for real recipients. |
| 15 | `public.notification_preferences` | EVOLVE | Map old per-routine toggles into new morning/evening/exception policy while preserving compatibility. |
| 16 | `public.household_routine_schedules` | EVOLVE | Add new brief schedule kinds; old nine kinds remain physical compatibility rows and are disabled/superseded per cutover. |
| 17 | `public.routine_checkin_sessions` | SUPERSEDE | Preserve compatibility/history; group reconciliation becomes canonical new evidence model. |
| 18 | `public.routine_checkin_session_items` | SUPERSEDE | Preserve compatibility/history; no dual reconciliation truth after cutover. |
| 19 | `public.evening_routine_preferences` | EVOLVE | Preserve current household routine configuration as input to future rule/read model; do not silently delete. |
| 20 | `public.calendar_connections` | KEEP | Existing provider connection handle reused. |
| 21 | `public.calendar_events_cache` | KEEP | Canonical observation of Google provider state, not Family Event household truth. |
| 22 | `public.calendar_event_occurrences` | KEEP | Provider occurrence projection reused; all-day rows must become visible to DailyBrief display even though conflict logic still excludes them. |
| 23 | `public.calendar_occurrence_busy_members` | KEEP | Timed conflict attribution continues. |
| 24 | `public.calendar_busy_classifications` | KEEP | Existing manual busy classification reused. |
| 25 | `public.calendar_busy_classification_members` | KEEP | Existing normalized classification membership reused. |
| 26 | `public.assignment_change_request_tasks` | SUPERSEDE | Existing v2 assignment-change scope mapping is migrated to new Request/Attempt/protected-scope provenance; retained read-only for audit/compat until verified cleanup. |

### 2.3 Private tables — 20/20 disposition

| # | Current table | Disposition | Detailed-design treatment |
|---:|---|---|---|
| 1 | `private.google_connections` | KEEP | Credential binding/encryption mechanics unchanged. |
| 2 | `private.google_watch_channels` | KEEP | Watch overlap/verification unchanged. |
| 3 | `private.google_sync_state` | KEEP | Sync token truth unchanged. |
| 4 | `private.google_sync_jobs` | KEEP | Queue/lease/coalescing unchanged. |
| 5 | `private.google_event_staging` | KEEP | 410/full-sync staging unchanged. |
| 6 | `private.google_write_operations` | KEEP | Google create/update idempotency retained; test context hard-blocked before write. |
| 7 | `private.webhook_inbox` | KEEP | LINE durable inbox/dedup retained. |
| 8 | `private.line_user_links` | KEEP | Real user LINE identity only; simulated member never receives its own production LINE link. |
| 9 | `private.pending_actions` | EVOLVE | Reuse preview/confirm queue; add revision/test/ActorRef-aware command context where necessary. |
| 10 | `private.raw_inputs` | EVOLVE | Reuse for short-lived private raw input; image/source intake gets separate private object/source model. No durable third-party OCR transcript. |
| 11 | `private.household_invites` | OUT-OF-SCOPE | Existing membership setup retained. |
| 12 | `private.line_link_tokens` | OUT-OF-SCOPE | Existing one-time link security retained. |
| 13 | `private.google_oauth_states` | KEEP | Existing replay-safe OAuth state retained. |
| 14 | `private.notification_outbox` | EVOLVE | Reuse durable delivery/retry/quota; **production only**. Synthetic test delivery must not write here. |
| 15 | `private.line_quota_state` | KEEP | Existing hard-cap accounting retained. |
| 16 | `private.line_quota_reservations` | KEEP | Existing atomic quota reservation retained. |
| 17 | `private.worker_run_receipts` | KEEP | Existing worker idempotency retained. |
| 18 | `private.jp_holidays` | KEEP | Existing holiday source drives non-workday morning brief. |
| 19 | `private.mutation_receipts` | EVOLVE | Preserve operation idempotency, but canonical actor identity must support ActorRef; simulated operations may not be forced into an operator user key. |
| 20 | `private.scheduled_dispatch_receipts` | EVOLVE | Add new brief schedule kinds/dedup keys; legacy routine dispatch receipts remain historical. |

This table is the implementation disposition inventory for all 46 current application tables. No table may be ignored merely because it is absent from older v6 prose.

## 3. BLOCKER closure — existing `task_instances` completion CHECKs

CURRENT `20260819000003_tasks_recurrence.sql` imposes both:

- `completion_mode <> 'subtasks' OR actual_completed_by_id IS NULL`
- for `completion_mode='whole' AND status='completed'`, `actual_completed_by_id IS NOT NULL`

Therefore the old design phrase “participant truth first; mirror legacy column temporarily” is not executable without first changing those CHECKs.

### 3.1 Phase 1 mandatory constraint replacement

The **first additive task-completion migration** must replace the two existing completion-mode CHECK constraints with explicit named constraints compatible with the new canonical participant model.

Implementation must first inspect the real production/catalog constraint names and definitions; do not guess auto-generated names from migration order.

Required new semantics:

1. `completion_mode='subtasks'`:
   - parent `actual_completed_by_id` remains `NULL`.
   - canonical performer identity is represented by canonical participant/subtask ActorRef data.
2. `completion_mode='whole' AND status='completed' AND test_context_id IS NULL`:
   - compatibility `actual_completed_by_id` is required while any old reader still exists.
   - it mirrors exactly one **compatibility-primary real performer**.
3. `completion_mode='whole' AND status='completed' AND test_context_id IS NOT NULL`:
   - `actual_completed_by_id` may be `NULL`; simulated actor cannot be inserted into a real-user FK.
   - canonical participant ActorRef(s) are required.
4. completed/completed_at invariant remains enforced.
5. The migration changes CHECK semantics only; it **does not drop the legacy column** and therefore is not the prohibited destructive cleanup.

### 3.2 Compatibility-primary participant rule

Multiple performers are equal in product semantics. `compatibility_primary` exists only to satisfy old physical readers during migration.

Canonical participant rows add:

- `compatibility_primary boolean not null default false`
- direct `test_context_id`

Rules:

- new **production whole-task** completion has exactly one active real participant marked compatibility-primary until all old readers are retired;
- if the recorder is also an explicitly declared performer, that performer is selected by default;
- otherwise use the first explicitly declared performer in the confirmed command payload;
- a later correction may change compatibility-primary only in the same atomic correction that updates canonical participants/audit;
- no UI/history text may call this participant “primary” or infer greater contribution;
- test/simulated completion has no legacy compatibility-primary user mirror requirement;
- `subtasks` never uses parent `actual_completed_by_id` as participant truth.

This closes the prior undefined “which performer is mirrored?” migration hole without changing the household meaning of multiple performers.

## 4. Request attempt → legacy `requests.status` compatibility projection

CURRENT `requests.status` is NOT NULL and CHECK-limited to:

- `pending`
- `accepted`
- `declined`
- `completed`
- `cancelled`

New attempt states cannot be stored directly in that column.

### 4.1 Projection table

| Canonical current attempt state | Legacy `requests.status` compatibility value | Notes |
|---|---|---|
| `pending` | `pending` | Old-compatible only before aggregate cutover. |
| `checking` | `pending` | Canonical UI must show `確認中`; old UI is prohibited after new-state cutover. |
| `consulting` | `pending` | Canonical UI must show `相談中`; old response buttons are prohibited after new-state cutover. |
| `awaiting_confirmation` | `pending` | Canonical UI renders terms confirmation, not old accept/decline. |
| `accepted` | `accepted` | Linked Task becomes execution truth. |
| `declined` | `declined` | Terminal attempt. |
| `expired` | `cancelled` | Compatibility only; canonical history remains `expired`, not “user cancelled”. |
| `cancelled` | `cancelled` | Terminal attempt. |

New runtime never independently sets `requests.status='completed'` when linked work completes. Existing historical `completed` rows remain untouched and backfill to accepted agreement + linked Task execution truth.

### 4.2 Current direct readers/writers that must be cut over together

At minimum the aggregate cutover inventory includes:

- `apps/web/src/features/requests/Requests.tsx`
  - direct `.from('requests').select('*')`
  - `request.status === 'pending'` currently renders `引き受ける / 断る`
- `apps/web/src/features/today/useTodayData.ts`
  - current request read used by Today/pending display
- current request Edge Functions / RPCs:
  - `accept-request`
  - `decline-request`
  - `cancel-request`
  - `accept-assignment-change-request`
  - corresponding `server_tx_*` request mutations
- LINE-native request/postback path introduced by `20260822000009_line_native_requests.sql`
- assignment-change implementation in `20260821000001_assignment_change_requests.sql`

No new attempt state may be enabled for a household while any user-visible reader for that same aggregate can still interpret legacy `pending` as unrestricted old accept/decline.

## 5. Aggregate-level atomic semantic cutover

The phase numbering in `02` must not be interpreted as “enable new writes, then later enable new reads”.

### 5.1 Preparation versus activation

- Phase 1: additive schema/constraint readiness.
- Phase 2: deterministic backfill + reconciliation.
- Phase 3: **deploy** new command adapters and new read models behind an inactive aggregate gate.
- Phase 4: **activate read + write semantics for one aggregate atomically** after both are ready.
- Phase 5: retire legacy direct writers/readers; physical cleanup later.

For each aggregate (`request`, `task_actual`, `shopping`, `daily_brief`, `family_event`):

1. deploy schema + canonical command + canonical reader;
2. run pre-cutover reconciliation;
3. route old public endpoint to the new adapter;
4. switch canonical read and write gate in the same household/release cutover;
5. only then permit first new-only semantic state.

There is no supported interval where `checking/consulting/anyone claim/multiple performer/waiting/mostly_done` can be written while the corresponding old current-truth reader remains active.

## 6. Rollback / feature-off contract after semantic cutover

### R0 — before any new semantic write

- full runtime rollback to old read/write is possible;
- additive schema/backfill may remain.

### R1 — new adapters deployed but no new-only state created

- feature activation can be cancelled;
- old public endpoints must still route through whichever command contract owns the aggregate at that moment;
- no parallel independent old/new write.

### P1 — first new-only canonical state exists

Examples: `checking`, `consulting`, `awaiting_confirmation`, `anyone` active claim, multiple performers, `waiting`, `mostly_done` evidence.

After P1:

- **legacy current-truth read rollback is forbidden**;
- **legacy semantic writer rollback is forbidden**;
- “rollback” means:
  - pause affected new mutations if necessary;
  - keep rendering canonical new truth through canonical or compatibility/degraded read model;
  - forward-fix the implementation;
- physical additive schema is not rolled back;
- legacy columns remain only as compatibility/audit until a separately reviewed cleanup.

Each aggregate cutover must persist/operationally record its P1 activation so an operator cannot accidentally flip a feature flag back to an unsafe legacy reader.

## 7. Simulated actor persistence and direct test scoping

### 7.1 Canonical ActorRef

Use one server-owned `domain_actor_refs` identity model:

- `real_user` -> same-household real `household_members.user_id`
- `simulated_member` -> `test_context_id + simulated_role`, no auth user/member row
- `system` -> explicit system actor

The operator user ID is never substituted as the simulated spouse's assignee, claimant, performer, recorder, requester, recipient, confirmer, or audit actor.

### 7.2 Actor-bearing truth that must use ActorRef

At minimum:

- task planned assignee
- anyone claimant
- task/subtask performer
- recorder
- task/audit actor
- request requester / recipient / attempt creator
- request terms confirmation
- reconciliation actor
- handover/share author and acknowledgement
- shopping assignee/claimant/participant/recorder
- Family Event/source/candidate resolver where actor identity is meaningful

Legacy real-user UUID columns are compatibility mirrors only for real production actors and may need CHECK/FK/nullability evolution. Simulated rows must not fabricate an operator/second user to satisfy them.

### 7.3 Direct `test_context_id` requirement

The earlier phrase “`test_context_id` **or a test-scoped parent aggregate**” is superseded for the following canonical business rows. They must directly store `test_context_id`:

- `task_instances`
- `task_actual_participants`
- `task_reconciliation_sessions`
- `task_reconciliation_session_items`
- `handovers`
- `requests`
- `request_attempts`
- `request_attempt_confirmations`
- `shopping_items`
- shopping claims/participants
- `family_events`
- change candidates / source documents created inside simulation

Child rows may additionally validate against parent test context; parent derivation is not a substitute for the direct leakage discriminator on these test-capable rows.

### 7.4 Read-path invariant

Every production read path defaults to `test_context_id IS NULL` or an equivalent server-enforced canonical filter:

- DailyBrief / Today
- morning/evening scheduled dispatch
- ordinary notification policy/outbox
- Requests
- History / analytics
- handover/share
- shopping
- event/prep
- recurrence/materialization inputs that would otherwise materialize real work

Test-mode read requires the exact active test context and operator authorization.

### 7.5 Side-effect invariants

- production `notification_outbox`: only production/non-test business state
- Google write: reject any simulated actor/test context with `TEST_SIDE_EFFECT_FORBIDDEN`
- real spouse consent/ack table: test-context rows never promoted to production consent
- production analytics: test excluded by default
- synthetic LINE: separate operator-only adapter/dedup; never production outbox

### 7.6 Migration impact on current real-user-FK columns

Where CURRENT NOT NULL/FK/check constraints prevent simulated canonical rows, Phase 1 must explicitly evolve those constraints/columns rather than substituting operator IDs.

Particularly inspect:

- `task_instances.created_by`, `planned_assignee_id`, `actual_completed_by_id`
- `task_subtask_instances.completed_by`
- `task_events.actor_id`
- `requests.requester_id`, `recipient_id`
- `handovers.author_id`
- `handover_reads.user_id`
- `private.pending_actions.actor_id`
- `private.mutation_receipts.actor_id`

A compatibility real-user field may remain populated for production rows, but canonical simulated identity is ActorRef + direct test context.

## 8. Shopping remains a first-class aggregate

Do **not** convert `shopping_items` into Tasks merely to reuse claim/actual machinery.

CURRENT shopping is already an independent aggregate with procurement lifecycle. Evolve it with the same responsibility/actual principles.

### 8.1 Canonical shopping responsibility

Add conceptually:

- `assignment_mode`: `person | unassigned | anyone`
- `assignee_actor_ref_id` nullable
- `active_claimant_actor_ref_id` nullable
- `claimed_at`
- `duplicate_sensitivity` default `avoid_duplicate` for ordinary one-item acquisition where double purchase matters
- `revision`
- direct `test_context_id`

CURRENT `assignee_id` remains production real-user compatibility mirror.

CURRENT `status='assigned'` is treated as a legacy compatibility representation of “wanted + person assignment”, not a separate new canonical procurement truth. New reads normalize procurement state independently from assignment/claim.

### 8.2 Shopping actual participants

Add a small `shopping_actual_participants` representation rather than hiding shopping completion inside Task participants.

Minimum semantics:

- shopping_item_id
- actor_ref_id
- action_kind (`ordered`,`purchased`,`arrived` as applicable)
- recorded_by_actor_ref_id
- direct test_context_id
- created/corrected audit

Ordinary UX remains one tap; multi-person participation is secondary.

### 8.3 `誰でもOK` shopping flow

`牛乳を買う / 誰でもOK`:

1. both can see item;
2. user taps `自分がやる` -> claim only; assignment mode stays `anyone`;
3. partner sees claimant/current state;
4. claimant may `手放す`;
5. rare emergency `引き継ぐ` is revision-checked/audited;
6. purchase/order completion clears active claim atomically and records participant;
7. duplicate-sensitive neutral `対応済み` can notify the other adult when behavior must change.

### 8.4 Undo/correction notification

If a duplicate-sensitive completion that produced a neutral `対応済み` notice is later undone/corrected back to actionable state, emit a revision-aware neutral correction when the other adult's behavior should change, e.g.:

`牛乳の買い物は未対応に戻りました`

or for medication correction:

`朝の薬は未対応として確認し直してください`

No actor praise/blame. Stale prior buttons remain invalid through revision check.

## 9. DailyBrief schedule persistence

CURRENT `household_routine_schedules.schedule_kind` CHECK contains exactly the v6-era nine kinds and cannot represent the accepted morning/evening anchor model.

### 9.1 Extend existing schedule table

Phase 1 evolves the CHECK to allow at least:

- `weekday_morning_brief`
- `nonworkday_morning_brief`
- `evening_brief`

Default rows:

- weekday morning: `06:30`
- weekend/JP-holiday morning: `09:00`
- evening: `20:30`

The old nine kinds remain physical rows during compatibility but are disabled/suppressed for a household when that household atomically cuts over to DailyBrief cadence.

### 9.2 Date-specific exception table

Add `household_routine_schedule_overrides` (name may be finalized at DDL review) with:

- household_id
- local_date
- brief schedule kind
- enabled/skip
- optional override `local_time`
- updated_by real ActorRef/user provenance
- revision / updated_at
- unique per household/date/kind

This supports travel/event-day one-off schedule changes without changing the base rule.

### 9.3 Existing UI/RPC disposition

Must explicitly evolve, not ignore:

- `apps/web/src/features/settings/RoutineSchedule.tsx`
- current `update-routine-schedule` Edge/RPC
- `notification_preferences`
- `household_routine_schedules`
- `scheduled_dispatch_receipts`
- current routine dispatcher

After aggregate cadence cutover, legacy checklist/check-in schedule rows cannot continue producing separate normal-day pushes that violate the two-anchor UX.

## 10. All-day event display versus conflict detection

CURRENT Google projection and multiple current Today/week/conflict readers intentionally contain `all_day_start is null` because v6 conflict detection excludes all-day events.

The new design must separate **display inclusion** from **assignment conflict inclusion**.

### 10.1 Conflict rule — unchanged

- all-day Google occurrence remains excluded from person-specific busy/conflict detection unless a future separately reviewed product requirement changes this.

### 10.2 DailyBrief display rule — changed

- all-day Family Events and all-day Google occurrences that are relevant to the household **must be visible** in DailyBrief/PWA schedule.
- DailyBrief gets an explicit `all_day_events[]`/equivalent section or typed entries inside schedule.
- no fake 00:00 time is invented.
- school events such as 運動会 / 遠足 / 食育 remain visible even though they do not create a timed calendar conflict.

### 10.3 Legacy read disposition

Current readers/RPCs that filter `all_day_start is null` may remain for the old timed conflict read, but the new DailyBrief display query must not reuse that predicate for schedule visibility.

Acceptance must include:

- nursery image -> all-day Family Event -> next relevant morning brief visible;
- Google all-day event -> DailyBrief visible;
- same all-day event -> no timed assignment conflict warning.

## 11. `待ち` current truth — binding physical mapping

The conceptual `attention_state` design is retained and is now a mandatory task physical extension:

- `attention_state`: `active | waiting`
- `waiting_note`
- `next_check_at`
- original `due_at` remains unchanged
- revision + audit events

Commands:

- `set-task-waiting`
- `update-task-waiting`
- `resume-task`

Read behavior:

- waiting + future next check -> ordinary incomplete nag suppressed
- next check due -> `waiting_checks`
- hard deadline risk may surface even while waiting
- no automatic state flip merely because time elapsed

Event prep uses the same task waiting dimension rather than adding another event-prep waiting status.

## 12. Task outcome/disposition mapping

New current task snapshot includes `outcome_reason` for terminal exception semantics.

| User meaning | Current operational representation |
|---|---|
| 未入力 / 結果不明 | no terminal outcome; task/reconciliation certainty remains unknown |
| できなかった | `status=skipped`, `outcome_reason=could_not_do` |
| 今回不要 | `status=skipped`, `outcome_reason=not_needed_this_occurrence` |
| occurrence expired by rule | `status=skipped`, `outcome_reason=expired_occurrence` |
| 中止 | `status=cancelled`, `outcome_reason=cancelled` |
| 再予定 | remains operationally open; reschedule mutation/audit stores prior schedule + `last_replanned_at`/equivalent, not a fake skip |

Existing legacy `skipped` rows are not guessed into a reason. They receive a compatibility `legacy_unknown_outcome` classification/report until explicitly corrected if necessary.

## 13. Consultation terms confirmation semantics

To close the “who already confirmed a proposed condition?” ambiguity:

1. A household participant who explicitly submits new terms, e.g. `18:30なら可能`, creates a new `terms_revision` and is **atomically recorded as confirmed for that exact revision**.
2. The other required participant must confirm the same revision before acceptance.
3. If AI/system merely synthesizes a candidate agreement from conversation without one participant explicitly proposing those exact terms, **zero confirmations are implied**; both participants confirm.
4. Any edit creates a new revision and invalidates confirmations from prior revisions.
5. One-sided confirmation never changes the formal assignment.

This keeps normal consultation light without treating an AI summary as consent.

## 14. Legacy request/backfill reconciliation gate

Before any household Request semantic cutover, generate a read-only reconciliation report covering at least:

- accepted/completed Request missing linked task;
- duplicate or invalid linked task relation;
- Request terminal state vs linked task state mismatch;
- `assignment_change_request_tasks` scope rows missing/extra/inconsistent with parent Request;
- accepted/completed/cancelled timestamps inconsistent with linked task timeline where deterministically checkable;
- legacy request `completed` whose linked task is not completed;
- accepted request whose linked task is cancelled/skipped or otherwise terminal in a contradictory way.

Rules:

- no inferred task creation;
- no inferred completion;
- no silent selection of one side as “correct”;
- anomaly blocks household semantic cutover until explicitly classified/resolved;
- report is repeatable/idempotent and retained as migration evidence.

## 15. Test-mode implementation dependency order

The prior late “test mode” package must be split by dependency.

### Foundation — before any actual-household one-user domain test

Must exist before testing new Requests/claims/actuals in the operator's real household:

- test simulation context
- canonical ActorRef including simulated member
- direct test scoping on canonical business rows
- server-derived execution context
- DB/adapter fail-closed side-effect guard
- minimal operator `🧪` synthetic delivery

### Later polish

Can come later:

- richer synthetic rendering UX
- test history/admin polish
- real spouse onboarding transition UI
- test-session cleanup conveniences

No rollout step may say “run one-user test” before the foundation above is complete.

## 16. Mandatory production-read leakage audit

Before enabling one-user test on an actual household, run a read-only audit proving test rows cannot enter ordinary production experience.

At minimum verify:

- Today/DailyBrief ordinary query excludes test
- 06:30/09:00/20:30 production dispatch excludes test
- History/analytics excludes test
- Requests ordinary view excludes test
- shopping ordinary view excludes test
- handover/share ordinary view excludes test
- recurrence materialization does not turn test definitions/state into production tasks
- notification outbox has no test rows
- Google write operations have no test rows

Any leakage is a release blocker.

## 17. Review closure matrix

### 17.1 Earlier independent detailed-design NO-GO

| Finding | Closure in current package |
|---|---|
| `待ち` truth missing | `02` current attention model + this doc §11 |
| simulated actor persistence incomplete | `02` ActorRef + this doc §7 |
| unsafe semantic rollback | `02/07` P1 rules + this doc §§5–6 |
| outcome reason current storage | `02` + this doc §12 |
| legacy Request mismatch audit | `02` + this doc §14 |
| one-user test dependency order | `07` current WP-DD3A + this doc §15 |

### 17.2 CURRENT-main physical alignment review

| Finding | Closure |
|---|---|
| BLOCKER: `task_instances` completion CHECK prevents mirror strategy | §§3.1–3.2 |
| HIGH: Request new states have no legacy status representation | §4 |
| HIGH: Phase write/read order contradiction | §5 |
| HIGH: test scope missing on canonical business rows | §§7,16 |
| HIGH: 46-table physical disposition missing | §2 |
| HIGH: shopping disconnected from claim/actual/safety | §8 |
| HIGH: DailyBrief schedule storage missing | §9 |
| HIGH: all-day events hidden by legacy read predicates | §10 |
| MEDIUM: outcome_reason storage | §12 |
| MEDIUM: legacy primary participant undefined | §3.2 |
| MEDIUM: consultation proposer confirmation undefined | §13 |
| Final-GO MEDIUM: mostly-done carryover | remains PASS in `04` |
| Final-GO MEDIUM: duplicate-sensitive neutral notification | §8.4 + `04`; includes undo correction |
| Final-GO MEDIUM: one-user synthetic delivery | §7 + `06`; domain persistence and read leakage now explicit |

## 18. Implementation/review gate

This design remains **NO IMPLEMENTATION** until fresh independent review of the current PR head returns `GO`.

Required gate:

- BLOCKER 0
- HIGH 0
- Requirements Baseline contradiction 0
- current physical schema inventory accounted for
- migration CHECK/compatibility strategy executable
- aggregate read/write cutover atomic
- test actor/test scope leakage closed
- all-day display and schedule persistence closed
- three Final-GO MEDIUMs judged PASS or safely carried with no HIGH dependency

If any BLOCKER/HIGH remains, do not merge PR #41, do not accept ADR 0013, and do not start implementation.