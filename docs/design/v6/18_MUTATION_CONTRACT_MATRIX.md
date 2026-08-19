# 18. Mutation Contract Matrix — v6 normative

## 0. Global contract

すべてのbrowser/LINE user-originated state mutationは以下を満たす。

1. public entrypoint = Edge Function
2. actor identityをJWTまたはverified LINE linkからserver derive
3. householdを`household_members`からserver derive
4. client supplied actor_id/household_idは認可根拠にしない
5. `operation_id UUID`必須
6. normalized request payload SHA-256を`request_hash`として計算
7. `private.mutation_receipts(actor_id,operation_id)`をtransaction内claim
8. same op + same hash →保存済みresultをreplay
9. same op + different hash →`IDEMPOTENCY_CONFLICT` 409
10. business mutation + task/request event + notification outbox + receipt resultは同transaction
11. server-only DB transaction functionは`PUBLIC,anon,authenticated` EXECUTE不可
12. Edge server roleのみ明示execute可

## 0A. Household setup

### `POST /mutations/households/create`
Input:
- operation_id
- household_name
- display_name

Auth:
- JWT user required
- caller must not already exist in `household_members`

Transaction:
1. claim mutation receipt
2. lock/check caller membership absent
3. create household with timezone=`Asia/Tokyo`
4. upsert profile for caller
5. create adult membership
6. seed default routine schedule rows
7. persist receipt result
8. commit

Replay returns same household id.

### `POST /mutations/household-invites/create`
Input:
- operation_id

Auth:
- caller active household adult

Transaction:
1. receipt claim
2. generate 256-bit cryptographic raw token server-side
3. SHA-256 token hash only stored
4. invite household/caller binding
5. expires_at=now()+24h
6. commit
7. return raw token exactly once in successful first response; receipt stores no raw token

Replay after first response:
- must not regenerate token
- return `INVITE_TOKEN_ALREADY_ISSUED` + existing invite id and allow caller to create a new invite with a new operation_id if raw token was lost

### `POST /mutations/households/join`
Input:
- operation_id
- raw_invite_token
- display_name

Auth:
- JWT user
- caller must not already belong to any household

Transaction:
1. normalize/hash raw token
2. claim mutation receipt
3. invite row `FOR UPDATE`
4. unused/unexpired validate
5. lock target household membership set
6. count active/adult rows; must be `< 2`
7. recheck caller no membership
8. upsert profile
9. create membership
10. set invite used_at/used_by
11. persist receipt
12. commit

Concurrent second claim / third adult / second household all fail transactionally.

## 0B. LINE account link claim

Link token creation is authenticated PWA mutation; claim is verified LINE webhook action.

### create link token
- operation_id
- actor household/user server-derived
- 256-bit raw token
- DB hash only
- TTL 10m
- raw token returned once

### claim link token
Input trust:
- `line_user_id` only from signed LINE webhook `source.userId`
- raw link token from user message/postback

Transaction:
1. hash token + lock
2. unused/unexpired
3. load bound household/user
4. reject line_user_id already linked to another user
5. reject user already active-linked to another LINE id
6. create/reactivate `line_user_links`
7. mark token used
8. commit

Unlinked actor cannot execute any Family Ops business mutation.

## 1. Manual task

### `POST /mutations/tasks/create`
Input:
- operation_id
- title
- scheduled_date
- due_local_time optional
- planned_assignee_user_id optional
- completion_mode
- subtasks optional
- routine_phase default `anytime`

Auth:
- actor household member
- assignee same household if provided

Mutation:
- task_instance origin=`manual`
- manual inline subtasks create
- task_event=`created`

Replay:
- same task id

### `POST /mutations/tasks/edit`
Input:
- operation_id
- task_id
- editable fields only: title/due/planned_assignee for active manual task

Precondition:
- not completed/cancelled
- recurring identity fields not edited here

Mutation:
- update
- task_event=`edited`

### `POST /mutations/tasks/cancel`
Precondition:
- todo/in_progress only
Mutation:
- status cancelled
- task_event cancelled
- linked pending request impossible; accepted linked request follows linked task lifecycle rule

## 2. Task completion

### `POST /mutations/tasks/complete`
Input:
- operation_id
- task_id
- completion_actor=`self|partner`

Auth:
- caller household member
- partner resolved server-side as other adult; no arbitrary user id

Whole mode:
- completed + completed_at + actual_completed_by

Subtask mode:
- reject direct task-level complete unless explicit `complete_remaining_subtasks=true`
- if true, complete remaining required subtasks with resolved actor
- task-level actual_completed_by remains null

Side effects:
- task_event(s)
- linked request completed if task fully completed
- notification according prefs

### `POST /mutations/subtasks/set-completion`
Input:
- operation_id
- subtask_instance_id
- completed bool
- completion_actor self|partner

Rules:
- completed true writes completed_by/at
- uncomplete allowed only while parent not terminal and caller household member
- parent completion recalculated atomically

## 3. Once reassignment

### `POST /mutations/tasks/reassign-once`
Input:
- operation_id
- task_id
- new_assignee_user_id

Precondition:
- recurring/manual active task
- new assignee same household

Mutation:
- planned_assignee only for this task instance
- task_event `reassigned_once`
- active routine sessions referencing old role superseded/rebuilt
- immediate assignment-change notification to both adults if date=today and scheduled digest already sent

## 4. Task definition

### create/edit/deactivate
Entrypoints:
- `/mutations/task-definitions/create`
- `/mutations/task-definitions/edit`
- `/mutations/task-definitions/deactivate`

Create/edit fields:
- title/category/routine_phase/completion_mode/sort_order/subtasks

Rules:
- code stable after create
- historical instances never rewritten by template title edit
- hard delete prohibited
- deactivate only

## 5. Request

### send
Input:
- operation_id
- recipient_user_id
- shared_title/shared_message
- due_at optional
- optional private raw input reference resolved server-side

Mutation:
- status pending
- **no task instance yet**
- notification recipient

### accept
Actor must be recipient.
transaction:
- lock pending request
- status accepted
- accepted_at
- create linked request-origin task
- link unique
- events/outbox

### decline
Actor recipient, pending only.
No task.

### cancel
Actor requester, **pending only**.
- status cancelled
- cancelled_at
- no task
- accepted/completed request cannot cancel

### linked task completion
- request accepted -> completed only when linked task reaches completed

## 6. Shopping

### add
- wanted
- purchase_method
- optional assignee/url/due

### assign/unassign
Allowed only status wanted/assigned.
- assign: status assigned, assignee set
- unassign: status wanted, assignee null

### order
Allowed wanted/assigned where method online/either/undecided.
- status ordered
- ordered_at now
- assignee caller if null optional

### purchase
Allowed wanted/assigned where method store/either/undecided.
- status purchased
- purchased_at now

### arrive
Allowed ordered only.
- status arrived
- arrived_at now
- ordered_at remains

### cancel
Allowed wanted/assigned/ordered only.
- status cancelled
- terminal

No transition out of purchased/arrived/cancelled in MVP.

## 7. Handover

### create
Input:
- operation_id
- raw/private candidate or already transformed shared_text
- period/categories/date

Rules:
- AI transformed result confirmed by author
- raw not public
- handover shared row immutable MVP
- important handover notification per prefs

### mark-read
Input handover_id.
- household/user server-derived
- upsert read receipt
- replay safe

## 8. Notifications

### mark-read
- recipient=self only
- read_at set once; replay returns current

### preferences update
- user=self
- only documented boolean preference fields
- schedule times are household-level separate mutation

## 9. Recurrence

### change recurrence
Input:
- operation_id
- rule id / task definition
- effective_from
- assignee_strategy
- planned_assignee (required only for fixed)
- scheduled_local_time
- conflict_window_minutes

Rules:
- old range close previous day
- new row create
- exclusion constraint must pass
- future `todo` only auto reconcile
- `in_progress/completed/skipped/cancelled` preserved
- materialize horizon after commit

### routine schedule settings
`POST /mutations/routine-schedules/update`

Input:
- operation_id
- schedule_kind
- enabled
- weekday only for weekly_digest
- local_time
- schedule_version is server-managed; client does not supply

Auth:
- household adult

Rules:
- unique household+kind
- local time no timezone suffix
- timezone fixed Asia/Tokyo
- validate weekly weekday 1..7
- increment schedule_version atomically
- same-day already-dispatched logical slot is not resent automatically

## 10. Routine check-in

### get session
Read via RLS or Edge GET.
Only session assignee and same-household partner may view; mutation permissions below.

### complete all
Actor=session assignee normally.
Partner may use PWA `相手が対応` but cannot impersonate via client user id.
Each task uses standard task completion logic.
One operation receipt at session command level plus deterministic child operation IDs derived from parent operation + task ID.

### item action
Input:
- operation_id
- session_id
- task/subtask id
- action=`complete|partner_handled|skip|uncomplete`

Authorization:
- session household
- caller household adult
- actor mapping server-side

### finalize session
Computed state:
- open: actionable incomplete items exist
- submitted: user explicitly checked and no remaining actionable incomplete item
- auto_closed: before reminder all items already terminal
- superseded: role reassignment invalidated session

## 9A. Configure evening routines

`POST /mutations/configure-evening-routines`

Input:
- operation_id
- rows[] task code, weekdays, strategy, fixed assignee?, local time?

Authorization:
- JWT household adult
- fixed assignee same household

Transaction:
1. receipt
2. validate complete batch
3. upsert evening_routine_preferences
4. update/deactivate recurrence rules
5. mark evening setup complete
6. targeted materialization
7. store receipt
8. commit

No partial save.

## 10A. Google Calendar OAuth state

### oauth-start
- state storage table=`private.google_oauth_states`
- JWT actor and household derive
- random 256-bit state
- DB stores SHA-256 hash only
- state row binds household/user/allowlisted return_to
- expires in 10m
- exact scopes `calendar.events` + `calendar.calendarlist.readonly`
- confidential web-server client + state; PKCEなし

### oauth-callback
- hash raw state
- state row `FOR UPDATE`
- unused/unexpired required
- callback actor context comes from state row
- code exchange
- encrypt refresh token
- create/update household-bound google connection
- mark state used
- second callback with same state rejected

## 11. Google Calendar create

Entrypoint Edge only.
Input:
- operation_id
- summary optional
- start/end/all-day
- busy_scope=`self|partner|family|unknown`

Operation:
1. derive deterministic Google event id `fo` + lowercase UUID hex without hyphens
2. claim `google_write_operations`
3. set private extended properties:
   - familyOpsOperationId
   - familyOpsBusyMemberIds where known
4. insert Google event
5. returned event cache upsert
6. operation success + etag

Timeout:
- retry same Google event id
- 409 -> GET same id, compare Family Ops op id/request hash, reconcile
- mismatch -> conflict, never silently overwrite

## 12. Google Calendar update

Precondition:
- same household
- accessRole writerWithoutPrivateAccess/writer/owner
- calendar timeZone Asia/Tokyo

Provider:
1. GET current
2. build Family Ops-owned PATCH
3. merge existing extendedProperties.private
4. events.patch + If-Match
5. sendUpdates='none'
6. omit attendees/reminders/attachments unless explicitly owned

Timeout => GET/reconcile.
412 => GET; already desired => success, else CALENDAR_ETAG_CONFLICT.
events.update prohibited.

## 12A. Manual calendar busy classification

Input:
- operation_id
- calendar_connection_id
- subject_event_id=`recurringEventId ?? event.id`
- original_start_time_key nullable
- busy_scope

Server derives member set from busy_scope.

Transaction:
1. receipt
2. validate same-household connection
3. upsert normalized parent classification under partial unique
4. replace child classification_members with same-household derived members
5. enqueue projection reapply
6. commit

Direct browser mutation denied.

## 13. AI rewrite confirmation

AI preview itself is not business mutation.
`confirm-request-draft` / `confirm-handover-draft`:
- author must confirm transformed text
- shared row created only after confirmation
- recipient never sees private raw text

## 14. Error codes

Minimum:
- `UNAUTHENTICATED`
- `NOT_HOUSEHOLD_MEMBER`
- `CROSS_HOUSEHOLD_RESOURCE`
- `IDEMPOTENCY_CONFLICT`
- `TASK_TERMINAL`
- `REQUEST_NOT_PENDING`
- `REQUEST_NOT_RECIPIENT`
- `REQUEST_CANCEL_NOT_ALLOWED`
- `INVALID_SHOPPING_TRANSITION`
- `RECURRENCE_OVERLAP`
- `SESSION_SUPERSEDED`
- `CALENDAR_ETAG_CONFLICT`
- `GOOGLE_REAUTH_REQUIRED`
- `HOUSEHOLD_ALREADY_JOINED`
- `HOUSEHOLD_FULL`
- `INVITE_EXPIRED`
- `INVITE_USED`
- `INVITE_TOKEN_ALREADY_ISSUED`
- `LINE_NOT_LINKED`
- `LINE_ID_ALREADY_LINKED`
- `OAUTH_STATE_INVALID`
- `OAUTH_STATE_EXPIRED`
- `OAUTH_STATE_USED`


## 12B. Google target calendar selection

Allow:
writerWithoutPrivateAccess/writer/owner.
Reject reader/freeBusyReader.
Require timeZone Asia/Tokyo.
Revalidate on target change and relevant 403.


## 15. v6 additional error codes

- CALENDAR_NOT_WRITABLE
- CALENDAR_TIMEZONE_UNSUPPORTED
- LINE_DELIVERY_UNKNOWN
- LINE_MONTHLY_APP_CAP_REACHED
- EVENING_ROUTINE_SETUP_REQUIRED
- EDGE_WORKER_UNAUTHORIZED
