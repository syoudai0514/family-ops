# 03. State Machines and Command Contracts

## 1. Command contract common rules

Every user mutation command must include:

- `operation_id`
- target aggregate identity when applicable
- `expected_revision` for stale-sensitive transitions
- actor derived server-side from JWT/LINE binding or validated simulation context, never trusted from body
- canonical `actor_ref_id` resolved server-side
- `execution_context` derived server-side (`production` or validated test simulation)

Transaction order:

1. authenticate / membership or active test simulation ownership
2. resolve canonical ActorRef
3. claim/replay mutation receipt
4. lock target aggregate/current attempt where needed
5. validate expected revision/state/test scope
6. mutate current truth
7. append audit/provenance
8. create notification intent(s)
9. persist mutation receipt result
10. commit

No provider network call inside DB transaction.

## 2. Task operational state

Current task status remains intentionally small:

- `todo`
- `in_progress`
- `completed`
- `skipped`
- `cancelled`

Do **not** add:

- `mostly_done`
- `unknown`
- `support`
- `claimed`
- `waiting`

as task status.

Those are separate dimensions/evidence. `待ち` is the orthogonal `attention_state=waiting` defined in Section 2.5.

### 2.1 Completion

`complete-task` conceptual command:

Input:

- task_id
- `performer_actor_ref_ids` (normally actor only; secondary UI may specify joint/other valid actor)
- expected_revision
- operation_id

Rules:

- open task only
- unknown performer cannot be silently guessed
- actor refs must belong to same household and same execution/test scope
- status -> completed
- participants upsert atomically
- active anyone claim cleared
- attention waiting metadata cleared from current snapshot
- task event appended
- linked accepted request remains provenance only
- notification policy evaluated after state change

If already completed:

- same semantic operation -> idempotent success
- different performer proposal -> return current participants and require explicit `add-joint-performer` / correction path
- never replace existing performer automatically

### 2.2 `今回は不要`

Command maps occurrence only to:

- `status=skipped`
- `outcome_reason=not_needed_this_occurrence`

Recurring definition remains unchanged。

### 2.3 `できなかった`

Requirements distinguishes explicit failure from unknown.

Representation:

- `status=skipped`
- `outcome_reason=could_not_do`

Other recognized reason:

- `expired_occurrence`

`not_needed_this_occurrence` / `could_not_do` / `expired_occurrence` are current snapshot reason dimension, not audit-only metadata and not extra top-level state. Legacy skipped rows with unknowable reason remain explicit legacy-unknown in compatibility reads; never guess.

### 2.4 Reschedule

For a manual/continuing task:

- update scheduled/target time
- keep same logical task identity if it is genuinely the same work
- append `rescheduled`

For recurrence occurrence where rescheduling would collide with next generated occurrence:

- current occurrence becomes explicit override/moved occurrence
- stable occurrence identity/history remains
- do not mutate recurrence rule unless user explicitly changes rule

### 2.5 `待ち` attention state

`待ち` is a nonterminal attention dimension, not a task status.

`set-task-waiting` input:

- task_id
- waiting_note optional
- next_check_at optional
- expected_revision
- operation_id

Preconditions:

- status in `todo|in_progress`
- same aggregate/test scope

Result:

- `attention_state=waiting`
- set/update waiting note and next check
- keep original `due_at`
- revision++
- append `waiting_started` or `waiting_updated`
- no completion/failure evidence

`resume-task-from-wait`:

- precondition attention_state=waiting
- set attention_state=active
- clear current waiting_note/next_check_at
- preserve history in `task_events`
- revision++

`update-task-waiting` can change note/next check without active resume.

Scheduled/read behavior:

- waiting task is excluded from ordinary incomplete nag and reconciliation eligibility by default
- `next_check_at <= now` resurfaces as a **確認対象**, not a failed/overdue task; read does not auto-resume it
- hard `due_at` risk can surface even while waiting
- if next_check is moved, old reminder/action becomes stale by revision
- terminal task transition clears current waiting snapshot
- event preparation uses these same task commands

No separate event-specific waiting workflow is invented.

## 3. Assignment state

Task assignment dimensions:

- `assignment_mode=person|unassigned|anyone`
- `planned_assignee_actor_ref_id`
- legacy planned user ID only as production compatibility mirror
- `assignment_source`
- `active_claimant_actor_ref_id` only for anyone

### 3.1 Person assignment change

Conceptual command `change-task-assignment`:

- if changing own/unassigned assignment without partner agreement requirement, apply direct with provenance
- if changing another person's agreed/expected responsibility and no prior agreement evidence, create assignment-change request attempt instead of mutating task
- if caller declares `already_agreed`, apply direct only for allowed scope, record `external_agreement_claim`, and create neutral correction notification for important tasks

Important tasks: transport, health/medication, deadline-critical appointment/submission by default.

`[違う]` action opens a correction command:

- restore pre-change effective assignment if still safe/current
- create new negotiation attempt
- do not invent provisional assignment state

All assignee/claim identity uses ActorRef. A production task may not be assigned/claimed by simulated ActorRef.

### 3.2 Anyone claim

`claim-task`:

Preconditions:

- assignment_mode=anyone
- task open
- active claimant is null
- actor ref allowed for aggregate execution scope

Result:

- active claimant ActorRef=actor
- revision++
- audit `claim_acquired`
- no “担当外サポート” semantics
- no routine praise notification

`release-task-claim`:

- only current claimant normally
- clear claimant
- audit

`takeover-task-claim`:

- allowed to another valid household actor only through secondary/rare action
- require current claimant/revision in precondition
- replace claimant atomically
- notify old claimant with neutral state change if production real recipient
- if old claimant simultaneously completed, completion wins and takeover returns latest completed state

No automatic claim expiry at deadline.

## 4. Recurrence rule change state

`change-recurrence` must separate:

1. create/supersede rule version
2. identify future materialized occurrences where `assignment_source=rule`
3. update only safe rule-derived occurrences
4. identify protected explicit agreement/override occurrences that conflict
5. create one grouped confirmation set by same agreement scope/series

A grouped confirmation is not one notification per occurrence.

If users disagree:

- existing explicit assignment remains effective
- disputed subset is represented by negotiation records
- rule itself may still apply to non-protected occurrences

Past occurrences and completed actuals are never recalculated.

## 5. Request lifecycle

Logical Request contains one or more Attempts. Requester/recipient/creator/confirmation identity is ActorRef-based; production requests use real-user ActorRefs, test requests may include simulated ActorRefs only within the same active test context.

### 5.1 Attempt state machine

| State | Allowed user action/event | Next |
|---|---|---|
| pending | `やる` | accepted |
| pending | `難しい` | declined |
| pending | `確認してみる` | checking |
| pending | `相談する` | consulting |
| pending | requester cancel | cancelled |
| checking | `やる` | accepted |
| checking | `難しい` | declined |
| checking | `相談する` | consulting |
| consulting | propose terms revision | consulting |
| consulting | one side confirms revision | awaiting_confirmation |
| awaiting_confirmation | other side confirms same revision | accepted |
| awaiting_confirmation | terms edited | consulting(new revision) |
| pending/checking/consulting/awaiting_confirmation | reply deadline | expired |
| any nonterminal | superseded by explicit new proposal only through controlled command | terminal old + new attempt |

Terminal states cannot transition back.

### 5.2 `確認してみる`

- acknowledges only “I am checking my own schedule”
- does not assign task
- requester gets at most one immediate status notification for entering checking
- status note updates do not each notify
- final `やる/難しい` notifies

### 5.3 `相談する`

Terms include the concrete outcome necessary to establish agreement, e.g.:

- assignee ActorRef/household role resolution
- date/time
- scope
- swap conditions

Every material terms edit increments `terms_revision` and invalidates prior confirmations.

Accepted only when all required ActorRefs confirm same revision.

### 5.4 Reply deadline expiry

Worker `expire-request-attempts` can run periodically.

Expiry transaction:

- lock attempt
- verify nonterminal + `reply_due_at <= now`
- state -> expired
- preserve underlying task/current assignment
- create “調整不成立/再提案可” intent if useful

Late LINE button references old attempt ID/revision:

- return `REQUEST_ATTEMPT_STALE`
- render `この依頼は期限切れです [再提案]`
- never set old attempt accepted

### 5.5 Accept light request

Atomic transaction:

- attempt accepted
- create/link task exactly once
- linked task assignment_mode=person, planned assignee ActorRef=recipient, assignment_source=agreement
- request keeps provenance

If a suitable existing task is the explicit target, link/update that task rather than duplicate create.

### 5.6 Accept assignment change

Atomic transaction:

- attempt accepted
- target task assignment snapshot changes
- `assignment_source=agreement`
- audit links request/attempt
- original assignee preserved in history

### 5.7 Decline

Light request:

- attempt declined
- no task generated by the request

Assignment change:

- attempt declined
- original assignment remains
- if underlying work cannot disappear, Today still shows original/unresolved operational responsibility

### 5.8 Accepted request change/cancel

Do not mutate accepted agreement silently.

Create new request attempt:

- `attempt_kind=change` or `cancel`
- current linked task remains current until change attempt accepted
- accepted change -> update linked task atomically
- accepted cancel -> linked task cancellation/appropriate outcome atomically

## 6. Request UI action contract

First-level UI only:

- `やる`
- `難しい`
- `その他の返答`

Second level:

- `確認してみる`
- `コメント付きで難しい`
- `相談する`

`コメント付きで難しい` transaction sends one final notification after comment confirmation; never “declined” then separate comment push.

## 7. Group reconciliation state machine

### 7.1 `全部やった`

Command `reconcile-task-group(response=all_done)`:

1. resolve current group task IDs server-side
2. eligible = own person-assigned tasks + own active claims, open, attention_state=active, expectation required/normal
3. exclude optional and waiting tasks
4. complete eligible tasks with actor performer
5. record reconciliation session + covered item snapshot with actor ref
6. return completed IDs and undo token/session ID

`undo` is bounded to actions still safe to revert; if another mutation changed a task after group completion, do not overwrite it. Show item-level conflict.

### 7.2 `大体やった`

`response=mostly_done`:

- snapshot group items (waiting tasks are not implicitly covered)
- create reconciliation session
- **no child task status change**
- suppress “please enter details” reconciliation prompt for those snapshot items

Operational next-day behavior:

- occurrence_ends -> occurrence closes as result unknown; never count failure
- until_done -> remains open and appears in weak `結果未確認` carryover group
- until_deadline -> remains open
- separate_next_occurrence -> next occurrence still materializes independently

### 7.3 Carryover-sensitive minimal follow-up — Final GO MEDIUM-1

Do not turn `大体やった` into a hidden full checklist.

If group includes safety/operationally costly `until_done` items, renderer may ask one compact follow-up after `大体やった`, e.g.:

`残すと明日に影響するものがあります: 洗濯物 / 食器 [どちらも済み] [結果未確認のまま] [個別]`

Rules:

- only carryover-sensitive subset
- one compact prompt
- user can choose `結果未確認のまま`
- no automatic failure

If no meaningful carryover impact, no follow-up.

### 7.4 `個別で答える`

Choose LINE or PWA.

LINE exception-first mode:

- user states exceptions
- server returns explicit preview of tasks that will be marked self-completed
- confirmation applies transaction

Per-item mode remains available but secondary.

## 8. Share / handover commands

### 8.1 Create info

`create-info` input:

- kind share/handover
- confirmed shared text
- visibility
- valid_until optional
- ack policy
- related task/event optional

New household-visible info creates immediate notification intent by default, with policy engine able to downgrade low-impact self/non-action info.

### 8.2 Acknowledge

`ack-info` only records acknowledgement receipt.

It never completes related task.

### 8.3 Correct/update info

Do not destructive overwrite important shared fact without history.

- new version/superseding record or update event
- current active info points to latest
- linked task impact becomes candidate when needed

## 9. Event commands

Conceptual commands:

- `create-family-event`
- `edit-family-event`
- `cancel-family-event`
- `mark-event-waiting-reschedule`
- `link-google-event`
- `resolve-change-candidate`

Event date change does not automatically rewrite completed prep task actuals.

For incomplete relative prep:

- compute proposed reschedule
- if task is purely relative and not protected/manual, candidate can be bulk-confirmed
- reservations/manual confirmed time stay separate protected value and produce warning/conflict

If an individual prep task is awaiting an external response, use Task `set-task-waiting`; `family_event.status=waiting_reschedule` is only for the event itself lacking a settled date, not a substitute for task waiting.

## 10. Candidate resolution

`resolve-change-candidate` input:

- candidate_id
- resolution accept/reject
- expected target revision/current snapshot hash
- optional edited patch

Accept:

- lock candidate + target
- if target changed since candidate creation, mark stale and require refreshed diff
- validate source authority
- apply allowed fields
- update field authority/protection
- audit human resolution

Reject:

- candidate terminal rejected
- no current state change

“latest external wins” path is forbidden.

## 11. Natural language command pipeline

Text/image interpretation is **proposal generation**, not mutation authority.

Pipeline:

1. parse one or multiple intents
2. deterministic validation and household context resolution
3. produce structured candidate list
4. ask only ambiguous parts
5. preview partner-visible wording and impactful changes
6. user confirms
7. execute standard commands

A single message may produce multiple commands, but confirmation should be grouped into one preview.

If only one candidate is ambiguous, do not block already-understood candidates from preview; user can confirm understood subset and resolve ambiguous item separately.

## 12. Notification intent generation

Mutation does not directly call LINE.

Intent includes:

- recipient ActorRef / resolved production recipient when allowed
- semantic type
- related aggregate/current revision
- urgency recommendation
- safety class
- bundle key
- expiry
- actor emphasis policy
- execution/test context

Renderer later reads latest state when practical, preventing stale “未完了” message after task has already completed.

## 13. Duplicate-sensitive completion — Final GO MEDIUM-2

Task `duplicate_sensitivity=avoid_duplicate|safety_critical` changes notification semantics.

When completion changes what another adult should do now:

- create immediate neutral state intent
- text emphasizes state, not performer credit

Examples:

- `朝の薬は対応済みです`
- `お迎えは対応済みです`
- `牛乳の買い物は対応済みです`

Default normal chores do not generate immediate completion push.

For safety-critical medication, current state retrieval must also ensure stale morning LINE action cannot mark/recommend a second administration without showing latest completed state.

## 14. Deep-link command continuity

LINE link carries only opaque resource/session identifiers and route context; no bearer token/private raw text.

After authentication, PWA resolves latest aggregate state server-side.

If LINE link is stale:

- show latest state
- disable invalid old action
- provide next valid action

## 15. Error contract additions

Candidate codes:

- `AGGREGATE_REVISION_CONFLICT`
- `REQUEST_ATTEMPT_STALE`
- `REQUEST_TERMS_REVISION_MISMATCH`
- `TASK_CLAIM_CONFLICT`
- `TASK_ALREADY_COMPLETED`
- `TASK_PERFORMER_CONFLICT`
- `TASK_WAITING_STATE_CONFLICT`
- `ACTOR_SCOPE_CONFLICT`
- `CANDIDATE_STALE`
- `PROTECTED_VALUE_CONFLICT`
- `TEST_SIDE_EFFECT_FORBIDDEN`

Error response must contain safe latest-state hints/deep link where useful, never raw private input/provider secret.

## 16. Worker responsibilities

### Existing workers retained

- webhook inbox processor
- pending action processor
- notification sender
- recurrence materializer
- Google sync worker

### New/extended scheduled logic

- expire request attempts
- compose morning/evening Daily Brief notifications
- surface waiting tasks whose next_check_at is due
- warn waiting tasks near hard due_at without auto-resume
- source document processing queue
- retention cleanup

Do not create one cron per household/task. Workers evaluate due rows from DB schedules.

## 17. State-machine invariants for tests

Mandatory property/invariant tests:

- terminal request attempt never reopens
- same terms revision must be confirmed by both required ActorRefs for consultation acceptance
- accepted Request execution status derives from linked task only
- `mostly_done` never completes child task
- waiting never becomes completion/failure and normal nag is suppressed until check/deadline risk
- next-check surfacing does not auto-resume waiting task
- skipped new writes always carry recognized outcome_reason
- rule change never rewrites non-rule assignment source
- anyone claim never changes assignment_mode
- takeover and completion race yields one coherent final state
- duplicate completion never silently replaces performer
- simulated performer/confirm/assignee is persisted as simulated ActorRef, never operator real ActorRef
- production aggregate cannot reference simulated ActorRef
- candidate cannot apply over newer target revision
- simulated actor cannot create production external side effect
- after semantic point-of-no-return, feature-off cannot restore legacy current-truth mutation/read semantics