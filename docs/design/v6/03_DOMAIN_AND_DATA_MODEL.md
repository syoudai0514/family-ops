# 03. Domain / Data Model — v6 normative

## 1. Membership

### public.households
- id uuid PK
- name text not null
- timezone text not null default `Asia/Tokyo` check (`timezone='Asia/Tokyo'`) — MVP fixed
- created_at / updated_at

### public.profiles
- user_id uuid PK -> auth.users(id)
- display_name text not null
- avatar_key text null
- created_at / updated_at

`household_id`は持たない。

### public.household_members
- household_id uuid not null
- user_id uuid not null
- member_role text not null check `adult`
- joined_at timestamptz not null
- PK(household_id,user_id)
- UNIQUE(user_id) for MVP

## 2. Task templates

### public.task_definitions
- id uuid PK
- household_id uuid not null
- code text not null
- title text not null
- category text not null
- `routine_phase` text not null default `anytime` check in (`morning`,`evening`,`anytime`)
- completion_mode text not null check in (`whole`,`subtasks`)
- is_active bool not null default true
- sort_order int not null default 0
- created_by uuid not null
- created_at / updated_at
- UNIQUE(household_id,code)
- UNIQUE(household_id,id)

### public.task_subtask_definitions
v5でhousehold_idを持たせ、source_definition composite FKを可能にする。

- id uuid PK
- household_id uuid not null
- task_definition_id uuid not null
- title text not null
- required bool not null default true
- sort_order int not null
- UNIQUE(household_id,id)
- composite FK `(household_id,task_definition_id)` -> task_definitions

Hard deleteは未使用templateであってもMVPでは行わず、parent task definition deactivateを基本とする。

## 3. Recurrence

ISO weekday: Monday=1 ... Sunday=7。

### public.recurrence_rules
- id uuid PK
- household_id uuid not null
- task_definition_id uuid not null
- weekday smallint not null 1..7
- slot_key text not null default `default`
- **assignee_strategy text not null default `fixed` check (`fixed`,`dropoff_assignee`,`pickup_assignee`,`nonpickup_adult`,`unassigned`)**
- planned_assignee_id uuid null
- **scheduled_local_time time null**
- **conflict_window_minutes int not null default 60 check 0..720**
- effective_from date not null
- effective_to date null
- active bool not null default true
- version int not null default 1
- supersedes_rule_id uuid null
- created_by uuid not null
- created_at / updated_at
- UNIQUE(household_id,id)

Assignment constraints:
- `fixed` -> planned_assignee_id not null
- `unassigned/dropoff_assignee/pickup_assignee/nonpickup_adult` -> planned_assignee_id null on rule
- dropoff/pickup task definitions themselves may not depend on role strategies that would create a cycle

Composite FK:
- hh/task definition
- hh/planned assignee
- hh/created_by
- hh/supersedes rule

Overlap:
- exact DB exclusion constraint with `btree_gist`
- key=(household_id,task_definition_id,weekday,slot_key)
- daterange(effective_from, coalesce(effective_to,'infinity'), '[]') WITH &&
- predicate active=true

### public.task_instances
- id uuid PK
- household_id uuid not null
- task_definition_id uuid null
- recurrence_rule_id uuid null
- logical_occurrence_key text null
- origin text not null check (`recurring`,`manual`,`request`,`calendar_assist`)
- title text not null
- category text not null
- `routine_phase` text not null check (`morning`,`evening`,`anytime`)
- scheduled_date date not null
- due_at timestamptz null
- planned_assignee_id uuid null
- completion_mode text not null
- status text not null check (`todo`,`in_progress`,`completed`,`skipped`,`cancelled`)
- actual_completed_by_id uuid null
- completed_at timestamptz null
- source text not null
- created_by uuid not null
- created_at / updated_at
- UNIQUE(household_id,id)
- partial UNIQUE(household_id,logical_occurrence_key) where non-null

Recurring materialization:
- resolve `assignee_strategy` for that date first
  - fixed -> rule.planned_assignee_id
  - dropoff_assignee -> same-date dropoff instance assignee
  - pickup_assignee -> same-date pickup instance assignee
  - nonpickup_adult -> other adult relative to same-date pickup assignee
  - unassigned -> null
- then snapshot resolved user into `task_instances.planned_assignee_id`
- unresolved role never guesses a user; it stays null and raises setup warning

Recurring due_at:
`scheduled_date + recurrence_rule.scheduled_local_time + household.timezone -> timestamptz`。
No scheduled_local_time => due_at null。

Logical key:
`rec:{task_definition_id}:{scheduled_date}:{slot_key}`。rule version/idは含めない。

### public.task_subtask_instances
- id uuid PK
- **household_id uuid not null**
- task_instance_id uuid not null
- source_definition_id uuid null
- title text not null
- required bool not null default true
- sort_order int not null
- is_completed bool not null default false
- completed_by uuid null
- completed_at timestamptz null
- UNIQUE(household_id,id)

Composite FK:
- `(household_id,task_instance_id)` -> task_instances
- `(household_id,source_definition_id)` -> task_subtask_definitions if non-null
- `(household_id,completed_by)` -> household_members if non-null

### public.task_events
append-only。
- id uuid PK
- household_id uuid not null
- task_instance_id uuid not null
- actor_id uuid not null
- event_type text not null
- payload jsonb not null default `{}`
- source text not null
- idempotency_key text null
- created_at
- partial UNIQUE(household_id,idempotency_key)

## 4. Requests

### public.requests
- id uuid PK
- household_id
- requester_id
- recipient_id
- shared_title
- shared_message
- due_at nullable
- status check (`pending`,`accepted`,`declined`,`completed`,`cancelled`)
- linked_task_instance_id uuid null unique
- accepted_at / declined_at / completed_at / **cancelled_at** nullable
- created_at / updated_at

Lifecycle fixed:
- send -> pending, no task
- recipient accept pending -> accepted + atomic task create/link
- recipient decline pending -> declined
- **requester cancel pending only -> cancelled**
- accepted request cannot cancel/decline
- linked task completed -> completed

## 5. Handovers

### public.handovers
- id uuid PK
- household_id
- author_id
- shared_text
- period check (`morning`,`day`,`evening`,`other`)
- categories text[]
- occurred_on date
- created_at
- UNIQUE(household_id,id)

### public.handover_reads
v5でhousehold_idを保持。
- household_id uuid not null
- handover_id uuid not null
- user_id uuid not null
- read_at timestamptz not null
- PK(handover_id,user_id)
- composite FK `(household_id,handover_id)` -> handovers
- composite FK `(household_id,user_id)` -> household_members

## 6. Shopping

### public.shopping_items
- id uuid PK
- household_id
- title
- purchase_method check (`store`,`online`,`either`,`undecided`)
- status check (`wanted`,`assigned`,`ordered`,`purchased`,`arrived`,`cancelled`)
- assignee_id nullable
- url nullable
- due_at nullable
- created_by
- ordered_at / purchased_at / arrived_at nullable
- created_at / updated_at
- UNIQUE(household_id,id)

State machine:
- wanted -> assigned or ordered or purchased or cancelled
- assigned -> wanted(unassign) or ordered or purchased or cancelled
- ordered -> arrived or cancelled
- purchased -> terminal
- arrived -> terminal
- cancelled -> terminal

Timestamp invariants:
- ordered/arrived => ordered_at not null
- arrived => arrived_at not null
- purchased => purchased_at not null
- status other than ordered/arrived => ordered_at null except cancelled-from-ordered may retain ordered_at as history
- status other than purchased => purchased_at null except future archival migration not MVP

## 7. Notifications

### public.user_notifications
- id uuid PK
- household_id
- recipient_user_id
- type
- title
- body
- payload jsonb
- dedup_key text not null
- read_at nullable
- created_at
- composite FK hh/recipient
- **UNIQUE(recipient_user_id,dedup_key)**

### public.notification_preferences
- household_id
- user_id
- request_line bool true
- handover_line bool true
- calendar_line bool true
- conflict_line bool true
- routine_completion_line bool false
- shopping_minor_line bool false
- **weekly_digest_line bool true**
- **daily_assignment_line bool true**
- **routine_checklist_line bool true**
- **routine_checkin_prompt_line bool true**
- in_app bool true
- updated_at
- PK(household_id,user_id)

## 8. Routine automation schedules

### public.household_routine_schedules
One row per household + schedule_kind.

- id uuid PK
- household_id uuid not null
- schedule_kind text check:
  - weekly_digest
  - daily_assignment
  - dropoff_checklist
  - dropoff_checkin
  - pickup_checklist
  - pickup_checkin
  - nonpickup_evening_checklist
  - nonpickup_evening_checkin
- weekday smallint null
- local_time time not null
- enabled bool not null default true
- schedule_version int not null default 1 check (schedule_version >= 1)
- updated_by uuid not null
- created_at / updated_at
- UNIQUE(household_id,schedule_kind)

Checks:
- weekly_digest -> weekday not null 1..7
- all other kinds -> weekday null

Initial values are in README/fixture.

### public.routine_checkin_sessions
- id uuid PK
- household_id uuid not null
- session_type check (`dropoff`,`pickup`,`nonpickup_evening`)
- scheduled_date date not null
- assignee_id uuid not null
- status check (`open`,`submitted`,`auto_closed`,`superseded`)
- opened_at timestamptz not null
- submitted_at nullable
- superseded_at nullable
- created_at / updated_at
- UNIQUE(household_id,session_type,scheduled_date,assignee_id)
- UNIQUE(household_id,id)
- composite FK hh/assignee

### public.routine_checkin_session_items
- id uuid PK
- household_id uuid not null
- session_id uuid not null
- task_instance_id uuid not null
- display_order int not null
- created_at
- UNIQUE(session_id,task_instance_id)
- composite FK `(household_id,session_id)` -> routine_checkin_sessions
- composite FK `(household_id,task_instance_id)` -> task_instances

Session item is a reference, not a duplicate status store. Current task status is canonical.

## 9. Calendar connection

### private.google_connections
- id uuid PK
- **household_id uuid not null**
- owner_user_id uuid not null
- google_subject text not null
- encrypted_refresh_token text not null
- encryption_version int not null
- scopes text[] not null
- status check (`active`,`reauth_required`,`revoked`)
- created_at / updated_at
- UNIQUE(household_id,id)
- composite FK `(household_id,owner_user_id)` -> household_members

### public.calendar_connections
- id uuid PK
- household_id
- provider default google
- external_calendar_id
- display_name
- google_connection_id uuid not null
- active bool
- last_incremental_sync_at
- last_occurrence_projection_at
- reauth_required bool
- created_at / updated_at
- UNIQUE(household_id,external_calendar_id)
- UNIQUE(household_id,id)
- composite FK `(household_id,google_connection_id)` -> private.google_connections(household_id,id)

## 10. Calendar canonical cache

### public.calendar_events_cache
Google Event resourceのcanonical stream cache。

- id uuid PK
- household_id
- calendar_connection_id
- google_event_id text not null
- recurring_event_id text null
- original_start_time jsonb null
- **title text null**
- description/location null
- starts_at / ends_at nullable
- all_day_start / all_day_end_exclusive nullable
- status text not null
- recurrence jsonb null
- creator_external_id null
- creator_mapped_user_id uuid null
- organizer_external_id null
- **transparency text null**
- google_updated_at null
- etag null
- raw_version_hash null
- tombstone_kind text null check (`deleted`,`cancelled_exception`) or null
- created_at / updated_at
- UNIQUE(calendar_connection_id,google_event_id)
- composite FK hh/calendar
- nullable composite FK `(household_id,creator_mapped_user_id)` -> household_members

Canonical semantics:
- untitled normal event allowed
- ordinary deleted event with id only: terminal tombstone may be retained for current sync transaction then active cache projection removed; never requires title
- cancelled recurring exception: minimal tombstone retained while parent/resource lifecycle requires it

UI title fallback only: `coalesce(title,'（無題）')`。

## 11. Calendar occurrence projection

### public.calendar_event_occurrences
- id uuid PK
- household_id
- calendar_connection_id
- occurrence_key
- google_event_id
- recurring_event_id nullable
- **title text null**
- starts_at / ends_at nullable
- all_day_start / all_day_end_exclusive nullable
- status
- creator_mapped_user_id nullable
- **transparency text null**
- projection_window_start/end
- source_google_updated_at
- created_at / updated_at
- UNIQUE(calendar_connection_id,occurrence_key)
- **UNIQUE(household_id,calendar_connection_id,occurrence_key)**
- composite FK hh/calendar
- nullable composite FK hh/creator

Rules:
- cancelled/deleted never active occurrence
- `transparency='transparent'` excluded from busy conflict
- all-day excluded from conflict in MVP

### public.calendar_occurrence_busy_members
- household_id uuid not null
- calendar_connection_id uuid not null
- occurrence_key text not null
- user_id uuid not null
- source text check (`family_ops_metadata`,`manual`)
- created_at
- PK(calendar_connection_id,occurrence_key,user_id)
- composite FK `(household_id,user_id)` -> household_members
- **composite FK `(household_id,calendar_connection_id,occurrence_key)` -> calendar_event_occurrences(household_id,calendar_connection_id,occurrence_key)**

Creator is not busy member.
Direct Google event without Family Ops busy metadata => unknown, no automatic user attribution.

## 12. Google watch/sync private model

### private.google_watch_channels
Multiple old/new overlap rows.
- channel_id unique
- calendar_connection_id
- resource_id
- token hash/encrypted verifier
- status check (`active`,`retiring`,`stopped`,`expired`)
- expires_at
- created_at/updated_at

### private.google_sync_state
- calendar_connection_id PK
- next_sync_token nullable
- last_success_at nullable
- last_full_sync_at nullable
- last_error sanitized

### private.google_sync_jobs
- id uuid PK
- calendar_connection_id
- status check (`queued`,`processing`,`done`,`dead`)
- reasons jsonb
- rerun_requested bool false
- attempts int
- next_attempt_at
- lease fields
- created_at/updated_at
- partial unique one active queued/processing per calendar

Transient errors return processing -> queued.

### private.google_event_staging
Full sync / 410 reset専用。

- sync_run_id uuid not null
- calendar_connection_id uuid not null
- google_event_id text not null
- event_json jsonb not null
- received_at timestamptz not null default now()
- PK(sync_run_id,google_event_id)
- index(calendar_connection_id,sync_run_id)
- composite FK `(household_id,...)`は持たず、calendar_connection_idからserver workerがhouseholdを解決するprivate staging

全page成功前にlive cacheへ反映しない。failure/stale stagingは24h cleanup。

## 13. Google write idempotency

### private.google_write_operations
- operation_id uuid PK
- household_id
- calendar_connection_id
- google_event_id text not null
- action check (`create`,`update`)
- request_hash text not null
- status check (`pending`,`succeeded`,`conflict`,`dead`)
- result_etag text null
- last_error null
- created_at/updated_at
- UNIQUE(calendar_connection_id,google_event_id)

## 14. General mutation idempotency

### private.mutation_receipts
- actor_id uuid not null
- operation_id uuid not null
- action_type text not null
- request_hash text not null
- result_type text null
- result_id uuid null
- result_payload jsonb null
- created_at
- PK(actor_id,operation_id)

## 15. Scheduled dispatch idempotency

### private.scheduled_dispatch_receipts
- id uuid PK
- household_id uuid not null
- schedule_kind text not null
- scheduled_local_date date not null
- recipient_user_id uuid not null
- dispatch_slot_key text not null
- notification_outbox_id uuid null
- created_at timestamptz not null default now()
- UNIQUE(household_id,schedule_kind,scheduled_local_date,recipient_user_id)

`dispatch_slot_key={schedule_kind}:{HH:MM}:v{schedule_version}` is diagnostic/audit only.

## 16. LINE / private queue / token exact schema — v5

v5 standalone packageでは以下を省略しない。

### private.webhook_inbox
- id uuid PK default gen_random_uuid()
- provider text not null check (`line`)
- provider_event_id text not null
- source_external_user_id text null
- payload jsonb not null
- status text not null default `received` check (`received`,`processing`,`done`,`dead`)
- attempts int not null default 0 check attempts>=0
- next_attempt_at timestamptz not null default now()
- lease_owner text null
- lease_token uuid null
- lease_until timestamptz null
- last_started_at timestamptz null
- last_error text null
- received_at timestamptz not null default now()
- processed_at timestamptz null
- UNIQUE(provider,provider_event_id)

### private.line_user_links
- id uuid PK
- household_id uuid not null
- user_id uuid not null
- line_user_id text not null
- status text not null default `active` check (`active`,`unlinked`)
- linked_at timestamptz not null default now()
- unlinked_at timestamptz null
- created_at / updated_at
- UNIQUE(user_id) — MVP one LINE identity per Family Ops user
- UNIQUE(line_user_id)
- composite FK `(household_id,user_id)` -> household_members
- active => unlinked_at null; unlinked => unlinked_at not null

Webhook actorはverified `source.userId` -> active line_user_linksでのみ解決する。

### private.pending_actions
- id uuid PK
- household_id uuid not null
- actor_id uuid not null
- source text not null check (`line`,`pwa`)
- action_type text not null
- normalized_payload jsonb not null
- operation_id uuid not null
- status text not null default `draft` check (`draft`,`confirmed`,`queued`,`executing`,`succeeded`,`cancelled`,`expired`,`dead`)
- confirmed_at timestamptz null
- expires_at timestamptz not null
- attempts int not null default 0
- next_attempt_at timestamptz not null default now()
- lease_owner text null
- lease_token uuid null
- lease_until timestamptz null
- last_started_at timestamptz null
- last_error text null
- result_type text null
- result_id uuid null
- created_at / updated_at
- UNIQUE(actor_id,operation_id)
- composite FK `(household_id,actor_id)` -> household_members

### private.raw_inputs
- id uuid PK
- household_id uuid not null
- author_user_id uuid not null
- kind text not null check (`request_draft`,`handover_draft`,`natural_language`)
- raw_text text null
- raw_payload jsonb null
- expires_at timestamptz not null
- created_at timestamptz not null default now()
- CHECK(raw_text is not null OR raw_payload is not null)
- composite FK `(household_id,author_user_id)` -> household_members

### private.household_invites
- id uuid PK
- token_hash text not null UNIQUE
- household_id uuid not null
- created_by uuid not null
- expires_at timestamptz not null
- used_at timestamptz null
- used_by uuid null
- created_at timestamptz not null default now()
- composite FK `(household_id,created_by)` -> household_members
- nullable composite FK `(household_id,used_by)` -> household_members
- token TTL at create = 24h

### private.line_link_tokens
- id uuid PK
- token_hash text not null UNIQUE
- household_id uuid not null
- user_id uuid not null
- expires_at timestamptz not null
- used_at timestamptz null
- created_at timestamptz not null default now()
- composite FK `(household_id,user_id)` -> household_members
- TTL at create = 10m

### private.google_oauth_states
- state_hash text PK
- household_id uuid not null
- user_id uuid not null
- return_to text null
- created_at timestamptz not null default now()
- expires_at timestamptz not null
- used_at timestamptz null
- composite FK `(household_id,user_id)` -> household_members
- TTL = 10m
- `return_to`はserver allowlistされたrelative app pathのみ

MVP Calendar OAuthは **confidential web-server client + state、PKCEなし** に固定する。

### private.notification_outbox
- id uuid PK
- household_id uuid not null
- recipient_user_id uuid not null
- channel text not null check (`line`,`in_app`)
- type text not null
- payload jsonb not null
- dedup_key text not null
- provider_retry_key uuid null
- provider_first_attempt_at timestamptz null
- provider_retry_expires_at timestamptz null
- business_expires_at timestamptz null
- quota_reservation_id uuid null
- priority text not null default `normal` check (`critical`,`normal`,`reminder`)
- quota_fallback_allowed bool not null default true
- status text not null default `queued` check (`queued`,`sending`,`sent`,`fallback`,`delivery_unknown`,`dead`)
- attempts int not null default 0
- next_attempt_at timestamptz not null default now()
- lease_owner text null
- lease_token uuid null
- lease_until timestamptz null
- last_started_at timestamptz null
- last_error text null
- sent_at timestamptz null
- created_at / updated_at
- UNIQUE(recipient_user_id,channel,dedup_key)
- provider_retry_key UNIQUE where non-null
- composite FK `(household_id,recipient_user_id)` -> household_members

`fallback`はquota/setting等によりLINE送信せずin-appへ正常降格したterminal stateでありdeadではない。

### private.line_quota_state
- billing_month date PK
- provider_limit int not null check provider_limit>=0
- provider_consumed int not null check provider_consumed>=0
- local_counted_success int not null default 0 check local_counted_success>=0
- soft_budget int not null default 180
- reserve int not null default 20
- app_hard_cap int not null default 200 check app_hard_cap=200
- last_provider_refresh_at timestamptz null
- updated_at timestamptz not null default now()

`effective_hard_limit=least(provider_limit,app_hard_cap)`.
`effective_usage=max(provider_consumed,local_counted_success)+active_reserved_units`.

### private.line_quota_reservations
- id uuid PK
- billing_month date not null
- notification_outbox_id uuid not null UNIQUE
- units int not null default 1 check units=1
- status text not null check (`reserved`,`committed`,`released`,`ambiguous`)
- provider_consumed_snapshot int not null
- reserved_at timestamptz not null default now()
- committed_at timestamptz null
- released_at timestamptz null
- updated_at timestamptz not null default now()
- FK billing_month -> line_quota_state
- FK notification_outbox_id -> notification_outbox

`reserved` and `ambiguous` count against available budget.

### private.worker_run_receipts
- worker_kind text not null
- logical_slot_key text not null
- created_at timestamptz not null default now()
- completed_at timestamptz null
- result jsonb null
- PK(worker_kind,logical_slot_key)

weekly preflight key example:
`weekly_digest_preflight:{household_uuid}:{week_start_YYYY-MM-DD}`。

## 17. One-time token retention

- expired/used LINE link tokens: hard delete after 7 days
- expired household invites: hard delete after 30 days
- no ambiguous tombstone-or-delete option

## 18. Persistent manual busy classification — normalized

### Identity helpers
`originalStartTimeKey(event)`:
- all-day: `date:YYYY-MM-DD`
- timed: originalStartTime.dateTime normalized to UTC second precision => `datetime:YYYY-MM-DDTHH:MM:SSZ`

`occurrenceKey(event)`:
- one-off: `event:{event.id}`
- recurring: `rec:{event.recurringEventId}:{originalStartTimeKey}`

`classificationSubjectId(event)=event.recurringEventId ?? event.id`.

Moved instance actual start never changes identity.

### public.calendar_busy_classifications
- id uuid PK
- household_id uuid not null
- calendar_connection_id uuid not null
- subject_event_id text not null
- original_start_time_key text null
- busy_scope text not null check (`self`,`partner`,`family`,`unknown`)
- created_by uuid not null
- created_at / updated_at
- UNIQUE(household_id,id)
- composite FK `(household_id,calendar_connection_id)` -> calendar_connections
- composite FK `(household_id,created_by)` -> household_members

Partial uniques:
- `(calendar_connection_id,subject_event_id)` WHERE original_start_time_key IS NULL
- `(calendar_connection_id,subject_event_id,original_start_time_key)` WHERE original_start_time_key IS NOT NULL

### public.calendar_busy_classification_members
- classification_id uuid not null
- household_id uuid not null
- user_id uuid not null
- created_at timestamptz not null default now()
- PK(classification_id,user_id)
- FK `(household_id,classification_id)` -> classifications(household_id,id)
- FK `(household_id,user_id)` -> household_members(household_id,user_id)

No uuid[] member array.

RLS:
- SELECT same household
- INSERT/UPDATE/DELETE server-only

Precedence:
instance override > series/event default > Family Ops metadata > unknown.

## 19. Evening routine setup state

### public.evening_routine_preferences
- household_id uuid not null
- task_definition_id uuid not null
- weekday smallint not null check 1..7
- enabled bool not null default true
- assignee_strategy text not null check (`pickup_assignee`,`nonpickup_adult`,`fixed`)
- fixed_assignee_id uuid null
- scheduled_local_time time null
- created_at / updated_at
- PK(household_id,task_definition_id,weekday)
- same-household FKs
- CHECK fixed strategy iff fixed_assignee_id not null

Setup wizard writes preferences + recurrence rules in one transaction.

## 20. Japan holiday cache

### private.jp_holidays
- local_date date PK
- name text not null
- source text not null default `cao_csv`
- source_fetched_at timestamptz not null
- updated_at timestamptz not null default now()

`is_nonworkday(date)` = Sat/Sun OR date exists here.

Official source:
`https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu_kyujitsu.csv`

Checked-in fixture is bootstrap/fallback.

## 21. Routine session reassignment generation

Keep unique `(household_id,session_type,scheduled_date,assignee_id)`.

A→B→A same day:
- lock existing superseded A session
- reconcile/rebuild items
- status=open
- `assignment_generation += 1`
- old LINE/postback generation => `SESSION_SUPERSEDED`
- do not insert duplicate A row

## 22. Notification history vs presentation setting

`public.user_notifications` is always durable notification history.
`in_app=false` suppresses badge/toast presentation only.
Quota fallback still persists a history row.
