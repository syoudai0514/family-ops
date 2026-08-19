# 15. DDL Contract — v6 normative

Sonnet must not choose alternate schema/security behavior where this document is explicit.

## 1. Common

- UUID PK default `gen_random_uuid()`
- timestamps `timestamptz not null default now()`
- mutable tables include updated_at
- FK columns indexed
- household query indexes start with household_id when applicable
- public household tables RLS enabled
- private schema grants revoked
- ISO weekday Monday=1..Sunday=7
- Google all-day end is exclusive
- extension `btree_gist` enabled for recurrence exclusion

## 2. Required household composite unique keys

At minimum:
- household_members PK(household_id,user_id)
- task_definitions UNIQUE(household_id,id)
- task_subtask_definitions UNIQUE(household_id,id)
- recurrence_rules UNIQUE(household_id,id)
- task_instances UNIQUE(household_id,id)
- task_subtask_instances UNIQUE(household_id,id)
- handovers UNIQUE(household_id,id)
- shopping_items UNIQUE(household_id,id)
- routine_checkin_sessions UNIQUE(household_id,id)
- calendar_connections UNIQUE(household_id,id)
- calendar_event_occurrences UNIQUE(household_id,calendar_connection_id,occurrence_key)
- private.google_connections UNIQUE(household_id,id)

## 3. Required same-household composite FK

### task definitions
- task_definitions(household_id,created_by) -> household_members
- task_subtask_definitions(household_id,task_definition_id) -> task_definitions

### recurrence/task
- recurrence_rules(hh,task_definition_id) -> task_definitions
- recurrence_rules(hh,planned_assignee_id) -> household_members
- recurrence_rules(hh,created_by) -> household_members
- recurrence_rules(hh,supersedes_rule_id) -> recurrence_rules
- task_instances(hh,task_definition_id) -> task_definitions
- task_instances(hh,recurrence_rule_id) -> recurrence_rules
- task_instances(hh,planned_assignee_id) -> household_members
- task_instances(hh,actual_completed_by_id) -> household_members
- task_instances(hh,created_by) -> household_members
- task_subtask_instances(hh,task_instance_id) -> task_instances
- task_subtask_instances(hh,source_definition_id) -> task_subtask_definitions
- task_subtask_instances(hh,completed_by) -> household_members
- task_events(hh,task_instance_id) -> task_instances
- task_events(hh,actor_id) -> household_members

### request/handover/shopping
- requests(hh,requester_id/recipient_id) -> household_members
- requests(hh,linked_task_instance_id) -> task_instances
- handovers(hh,author_id) -> household_members
- handover_reads(hh,handover_id) -> handovers
- handover_reads(hh,user_id) -> household_members
- shopping_items(hh,assignee_id/created_by) -> household_members

### routine automation
- household_routine_schedules(hh,updated_by) -> household_members
- routine_checkin_sessions(hh,assignee_id) -> household_members
- routine_checkin_session_items(hh,session_id) -> routine_checkin_sessions
- routine_checkin_session_items(hh,task_instance_id) -> task_instances

### notification
- user_notifications(hh,recipient_user_id) -> household_members
- notification_preferences(hh,user_id) -> household_members

### Google
- private.google_connections(hh,owner_user_id) -> household_members
- calendar_connections(hh,google_connection_id) -> private.google_connections(hh,id)
- cache/projection(hh,calendar_connection_id) -> calendar_connections
- cache/projection(hh,creator_mapped_user_id) -> household_members nullable
- busy_members(hh,user_id) -> household_members
- busy_members(hh,calendar_connection_id,occurrence_key) -> calendar_event_occurrences(hh,calendar_connection_id,occurrence_key)

## 4. ON DELETE — fixed

No choices left.

Identity lifecycle:
- auth user -> profile CASCADE
- auth user -> household_members CASCADE
- household -> household_members/business household-owned rows CASCADE only when household itself is explicitly destroyed by future admin flow

Historical/reference model:
- task definition referenced by recurrence/task history: **RESTRICT**
- recurrence rule referenced by task history: **RESTRICT**
- task instance referenced by task events/request/session items: **RESTRICT**
- handover referenced by read receipts: RESTRICT for normal app; future household destroy may explicit cascade transaction
- calendar connection referenced by cache/history: RESTRICT; deactivate instead

MVP user flows expose no hard delete for historical business records.
Definitions/rules/connections are deactivated/closed.

Ephemeral private queues/tokens may hard delete by cleanup.

## 5. Unique constraints

- household_members unique(user_id)
- task_definitions unique(hh,code)
- task_instances partial unique(hh,logical_occurrence_key) where non-null
- task_events partial unique(hh,idempotency_key) where non-null
- requests unique linked_task_instance_id where non-null
- shopping no duplicate constraint by title
- user_notifications unique(recipient_user_id,dedup_key)
- household_routine_schedules unique(hh,schedule_kind)
- routine session unique(hh,session_type,scheduled_date,assignee_id)
- routine_checkin_sessions.assignment_generation int not null default 1
- routine session item unique(session_id,task_instance_id)
- calendar_connections unique(hh,external_calendar_id)
- calendar cache unique(calendar_connection_id,google_event_id)
- occurrence unique(calendar_connection_id,occurrence_key)
- occurrence unique(hh,calendar_connection_id,occurrence_key)
- busy member PK(calendar_connection_id,occurrence_key,user_id)
- webhook_inbox UNIQUE(provider,provider_event_id)
- notification_outbox unique(recipient_user_id,channel,dedup_key)
- notification_outbox provider_retry_key unique where not null
- mutation_receipts PK(actor_id,operation_id)
- google_write_operations PK(operation_id), unique(calendar_connection_id,google_event_id)
- line/invite token hash unique
- line_user_links unique(user_id), unique(line_user_id)
- google_oauth_states PK(state_hash)
- worker_run_receipts PK(worker_kind,logical_slot_key)
- google_event_staging PK(sync_run_id,google_event_id)
- line_quota_state PK(billing_month)
- google watch channel_id unique
- google sync partial unique one active queued/processing per calendar
- scheduled_dispatch_receipts UNIQUE(hh,schedule_kind,scheduled_local_date,recipient_user_id)

## 6. Recurrence exclusion

Use PostgreSQL exclusion constraint, not app-only lock fallback.

Conceptually:
```sql
EXCLUDE USING gist (
  household_id WITH =,
  task_definition_id WITH =,
  weekday WITH =,
  slot_key WITH =,
  daterange(effective_from, coalesce(effective_to,'infinity'::date), '[]') WITH &&
) WHERE (active)
```

If exact SQL requires casting infinity/open-ended range adjustment, preserve semantic contract and prove with tests.

## 7. Static checks

### recurrence
- weekday 1..7
- assignee_strategy valid
- fixed => planned_assignee_id not null
- all non-fixed strategies => planned_assignee_id null on rule
- effective_to null or >= effective_from
- conflict_window_minutes 0..720

### task
- completion_mode valid
- status valid
- subtask mode => task actual_completed_by null
- completed => completed_at not null
- noncompleted => completed_at null
- whole completed => actual_completed_by not null

### subtask
- completed true => completed_by/at not null
- false => both null

### request
- requester != recipient
- pending => lifecycle timestamps null
- accepted => accepted_at only
- declined => declined_at only
- cancelled => cancelled_at only and no accepted/completed
- completed => accepted_at+completed_at, no declined/cancelled

### routine schedule
- weekly_digest weekday not null 1..7
- all other kinds weekday null

### routine session
- submitted => submitted_at not null
- superseded => superseded_at not null

### queue
- attempts >=0
- processing/sending/executing lease requires owner/token/until
- terminal state clears lease

### Google sync job
status only queued/processing/done/dead.

### Calendar
- title nullable
- timed/all-day provider field combos validated softly enough for deleted/cancelled tombstones

## 8. Function grants / RPC transport

Atomic Edge transaction entrypoints are `public.server_tx_*` only.

Immediately after each server function create:
```sql
REVOKE ALL ON FUNCTION public.server_tx_xxx(...) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.server_tx_xxx(...) FROM anon;
REVOKE ALL ON FUNCTION public.server_tx_xxx(...) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.server_tx_xxx(...) TO service_role;
```

- server_tx functions are `SECURITY INVOKER`
- Edge calls via service-role supabase-js RPC
- private schema is not in Exposed Schemas
- worker/internal helper functions are not browser executable
- default PUBLIC function EXECUTE privileges revoked
- SECURITY DEFINER helper only with empty search_path

CI must assert:
- anon RPC denied
- authenticated RPC denied
- service_role RPC succeeds
- browser private table access denied

## 9. Private privileges

- `private` schema is not an exposed schema
- schema USAGE revoked from anon/authenticated/PUBLIC
- private tables/sequences/routines revoked from anon/authenticated/PUBLIC
- service_role gets explicit `USAGE ON SCHEMA private` and only required SELECT/INSERT/UPDATE/DELETE/sequence privileges for Edge/worker transactions
- default privileges locked so new private objects are not browser reachable

## 10. Queue indexes

- webhook_inbox(status,next_attempt_at,lease_until,created_at)
- notification_outbox(status,next_attempt_at,lease_until,created_at)
- google_sync_jobs(status,next_attempt_at,lease_until,created_at)
- pending_actions(status,next_attempt_at,lease_until,expires_at)
- line_user_links(line_user_id,status)
- household_invites(household_id,expires_at,used_at)
- line_link_tokens(user_id,expires_at,used_at)
- google_oauth_states(expires_at,used_at)

## 11. Business indexes

Tasks:
- (hh,scheduled_date,status)
- (hh,planned_assignee_id,scheduled_date,status)
- (hh,routine_phase,scheduled_date,planned_assignee_id,status)

Requests:
- (hh,recipient_id,status,due_at)

Shopping:
- (hh,status,due_at)

Handovers:
- (hh,occurred_on desc,created_at desc)

Routine:
- schedules(hh,enabled,schedule_kind)
- sessions(hh,scheduled_date,assignee_id,status)

Calendar:
- cache(hh,calendar_connection_id,google_updated_at)
- occurrences(hh,starts_at)
- busy_members(hh,user_id,calendar_connection_id,occurrence_key)
- calendar_busy_classifications(hh,calendar_connection_id,subject_event_id,original_start_time_key)
- calendar_busy_classification_members(hh,classification_id,user_id)
- watch(calendar_connection_id,status,expires_at)

## 12. Google sync state machine

`google_sync_jobs` statuses exactly:
- queued
- processing
- done
- dead

Transient error must update same row back to queued.
No failed status.

## 13. Google tombstone contract

- title/start/end nullable in canonical cache
- deleted/cancelled minimal row must not violate CHECK/NOT NULL
- active occurrence projection excludes cancelled/deleted
- ordinary deleted tombstone retention exactly 30d
- cancelled recurring exception retained while parent recurring canonical event exists or until projection horizon passes exception, whichever is later

## 14. Google write operation

Deterministic ID function must be pure/tested:
`google_event_id = 'fo' || replace(operation_uuid::text,'-','')`

Function validates lowercase and allowed character set before API call.

## 15. One-time tokens / OAuth state

Claim:
- SHA-256 raw token/state
- lock matching unused/unexpired row
- bind to expected household/user
- mark used atomically
- second claim fails

TTL:
- line link token 10m; terminal cleanup 7d
- household invite 24h; expired/used cleanup 30d
- Google OAuth state 10m; terminal cleanup 24h

MVP Calendar OAuth = confidential web-server client + state, PKCEなし.

## 16. Scheduled dispatch

Receipt claim + notification outbox insert must be one transaction.
Bundle may produce one outbox row referenced by multiple schedule receipts.

`dispatch_slot_key` exact format:
`{schedule_kind}:{HH:MM}:v{schedule_version}`

Only semantic one-send unique is enforced:
`UNIQUE(household_id,schedule_kind,scheduled_local_date,recipient_user_id)`.
`dispatch_slot_key` is audit data, not a unique key.

Same-day schedule edit:
- if no receipt exists yet, new time/version may send once at new due time
- if receipt already exists for that logical day/week + recipient, do **not** resend automatically
- explicit resend UI is MVP non-goal

`household_routine_schedules.schedule_version` increments on every settings mutation.

## 17. Migration gate

From empty local DB:
1. enable required extensions
2. `supabase db reset`
3. normalized seed
4. schema lint
5. CHECK/FK/exclusion tests
6. function EXECUTE privilege tests
7. RLS matrix
8. token replay tests
9. mutation receipt tests
10. queue lease/recovery tests
11. scheduled dispatch dedup tests

All green before WP1 gate closes.

## 18. v5 exact private table DDL checklist

Migration must implement exact columns/checks described in `03_DOMAIN_AND_DATA_MODEL.md` for:
- private.webhook_inbox
- private.line_user_links
- private.pending_actions
- private.raw_inputs
- private.household_invites
- private.line_link_tokens
- private.google_oauth_states
- private.notification_outbox
- private.line_quota_state
- private.worker_run_receipts
- private.google_event_staging

No placeholder `jsonb-only queue` implementation is accepted.

## 19. MVP active-adult invariant

`join-household` transaction:
- lock household/adult membership set
- current member count must be `< 2`
- invite and count check occur in same transaction
- third adult rejected even under concurrent joins

`household_members.user_id` remains UNIQUE globally for MVP, so second-household membership is DB-rejected.

## 20. Fixed timezone

`households.timezone` has CHECK exactly `Asia/Tokyo` for MVP.
Timezone setting mutation/UI does not exist.


## 21. v6 calendar classification DDL

Partial unique:
```sql
CREATE UNIQUE INDEX uq_busy_class_series_default
ON public.calendar_busy_classifications(calendar_connection_id,subject_event_id)
WHERE original_start_time_key IS NULL;

CREATE UNIQUE INDEX uq_busy_class_instance
ON public.calendar_busy_classifications(calendar_connection_id,subject_event_id,original_start_time_key)
WHERE original_start_time_key IS NOT NULL;
```

Child members:
- PK(classification_id,user_id)
- FK(household_id,classification_id) -> classifications(household_id,id)
- FK(household_id,user_id) -> household_members(household_id,user_id)


## 22. v6 LINE retry/quota DDL

notification_outbox:
- provider_first_attempt_at
- provider_retry_expires_at
- business_expires_at
- quota_reservation_id
- status includes delivery_unknown

`private.line_quota_reservations` exact schema from 03.
`APP_LINE_MONTHLY_HARD_CAP=200`.


## 23. v6 evening/holiday DDL

- public.evening_routine_preferences
- private.jp_holidays
- assignment_generation


## 24. Contract/schema lint

CI introspects resulting migration and validates every documented column referenced by unique/FK/index/mutation contract.
Nonexistent `event_id` reference for webhook_inbox fails CI.
