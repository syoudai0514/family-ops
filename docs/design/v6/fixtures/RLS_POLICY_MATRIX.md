# RLS Policy Matrix — v6 normative

Legend:
- READ HH = authenticated caller is household member
- READ SELF = caller is recipient/user row
- SERVER MUTATION = no direct client DML; Edge -> server-only tx RPC
- SERVER ONLY = no direct browser grant

| table | SELECT | INSERT/UPDATE/DELETE | household / identity path |
|---|---|---|---|
| households | READ HH | SERVER MUTATION | household.id -> household_members |
| profiles | self or same-HH adults | SERVER MUTATION profile-safe fields | profile.user_id -> household_members |
| household_members | same HH | SERVER ONLY | row household_id |
| task_definitions | READ HH | SERVER MUTATION | row household_id |
| task_subtask_definitions | READ HH | SERVER MUTATION | row household_id + parent composite FK |
| recurrence_rules | READ HH | SERVER MUTATION | row household_id |
| task_instances | READ HH | SERVER MUTATION | row household_id |
| task_subtask_instances | READ HH | SERVER MUTATION | row household_id + parent composite FK |
| task_events | READ HH | append SERVER ONLY | row household_id |
| requests | READ HH | SERVER MUTATION lifecycle | row household_id |
| handovers | READ HH | create SERVER MUTATION; otherwise immutable MVP | row household_id |
| handover_reads | READ HH | mark-read SERVER MUTATION | row household_id + user composite FK |
| shopping_items | READ HH | SERVER MUTATION | row household_id |
| user_notifications | READ SELF | insert SERVER ONLY; mark-read SERVER MUTATION | recipient_user_id=auth.uid() |
| notification_preferences | READ SELF | self SERVER MUTATION | (hh,user) membership |
| household_routine_schedules | READ HH | SERVER MUTATION | row household_id |
| routine_checkin_sessions | READ HH | SERVER MUTATION/state server | row household_id |
| routine_checkin_session_items | READ HH | SERVER ONLY references | row household_id + session/task composite |
| calendar_connections | READ HH | OAuth/server mutation | row household_id |
| calendar_events_cache | READ HH | SERVER ONLY sync | row household_id |
| calendar_event_occurrences | READ HH | SERVER ONLY projection | row household_id |
| calendar_occurrence_busy_members | READ HH | SERVER ONLY sync/manual classification mutation | row household_id |

## Direct grants

Authenticated browser role:
- SELECT only where policy says so
- no INSERT/UPDATE/DELETE on business tables

Anon:
- no business table access

## Functions

Server transaction functions:
- `REVOKE EXECUTE FROM PUBLIC, anon, authenticated`
- explicit server/service role grant only

Read helper functions exposed to authenticated must:
- be listed explicitly
- use auth.uid()
- not accept actor_id as trust input

## Private schema

PUBLIC/anon/authenticated:
- no schema USAGE
- no table/sequence/function privileges

## Mandatory tests

1. A cannot SELECT B task/profile/subtask/request/shopping/calendar
2. A cannot insert/update B via Edge payload spoof
3. A service-side direct SQL insert with B completed_by fails FK
4. foreign handover read user fails FK
5. cross-HH Google credential/calendar connection fails FK
6. cross-HH mapped creator/busy member fails FK
7. caller cannot read partner's user_notification row if recipient differs
8. authenticated cannot execute server tx RPC directly
9. anon cannot execute server tx RPC
10. Edge server role can execute tx after own authorization

## v6 RPC/private-schema additions

| case | role | action | expected |
|---|---|---|---|
| server tx direct | anon | rpc(public.server_tx_create_task) | DENY |
| server tx direct | authenticated | rpc(public.server_tx_create_task) | DENY |
| server tx Edge | service_role | rpc(public.server_tx_create_task) | ALLOW |
| private LINE links | authenticated | select private.line_user_links | DENY |
| private OAuth state | authenticated | select private.google_oauth_states | DENY |
| busy member cross HH | service bug insert A occurrence + B user | insert | FK DENY |
| busy member same HH | service role | insert | ALLOW |

## v6 calendar busy classification
| table | op | same HH | cross HH | browser write |
|---|---|---|---|---|
| calendar_busy_classifications | SELECT | ALLOW | DENY | n/a |
| calendar_busy_classifications | I/U/D | server | DENY | DENY |
| calendar_busy_classification_members | SELECT | ALLOW | DENY | n/a |
| calendar_busy_classification_members | I/U/D | server | DENY | DENY |
