# 09. API / Edge Functions / Workers — v6 normative

## 1. Public client access

- direct SELECT to RLS-safe public tables only
- direct INSERT/UPDATE/DELETE on business state tables revoked
- every user mutation enters through an Edge Function
- Edge calls a server-only transaction RPC when atomic DB work is required
- private schema never accessed by browser

## 2. Edge auth

Normative:
- `EDGE_FUNCTION_AUTH_MATRIX.md`
- `supabase/config.toml`

Classes:
1. user mutation => verify_jwt=true
2. provider => false + provider auth
3. worker => false + worker token

No function may be deployed without matrix classification.
Provider/worker authentication succeeds before service-role DB access.

## 3. Server-only transaction RPCs — fixed public entry schema

Edgeからatomic DB transactionを呼ぶ方法は1つに固定。

Entrypoint examples:
- `public.server_tx_create_household`
- `public.server_tx_create_household_invite`
- `public.server_tx_join_household`
- `public.server_tx_create_task`
- `public.server_tx_complete_task`
- `public.server_tx_set_subtask_completion`
- `public.server_tx_reassign_once`
- `public.server_tx_send_request`
- `public.server_tx_accept_request`
- `public.server_tx_shopping_transition`
- `public.server_tx_change_recurrence`
- `public.server_tx_routine_checkin_action`

For every `public.server_tx_*`:
- `SECURITY INVOKER`
- `REVOKE EXECUTE FROM PUBLIC, anon, authenticated`
- `GRANT EXECUTE TO service_role`
- Edge uses service-role supabase-js `rpc()`
- `private` schema is **not** an exposed schema
- service_role has explicit private schema USAGE + minimum table privileges
- anon/authenticated have no private schema privileges

Internal helpers may live in private schema. SECURITY DEFINER only if unavoidable, with `SET search_path=''`.

Contract in `18_MUTATION_CONTRACT_MATRIX.md` is normative.

## 4. User mutation endpoints

Minimum endpoints:

### Household
- `create-household`
- `create-household-invite`
- `join-household`

### Tasks
- `create-task`
- `edit-task`
- `cancel-task`
- `complete-task`
- `set-subtask-completion`
- `reassign-task-once`
- `create-task-definition`
- `edit-task-definition`
- `deactivate-task-definition`
- `change-recurrence`
- `configure-evening-routines`

### Requests
- `send-request`
- `accept-request`
- `decline-request`
- `cancel-request`

### Shopping
- `add-shopping-item`
- `assign-shopping-item`
- `order-shopping-item`
- `purchase-shopping-item`
- `arrive-shopping-item`
- `cancel-shopping-item`

### Handover/notifications
- `create-handover`
- `mark-handover-read`
- `mark-notification-read`
- `update-notification-preferences`
- `update-routine-schedule`
- `create-line-link-token`
- `unlink-line-account`

### Routine check-in
- `get-routine-session`
- `complete-routine-session`
- `routine-session-item-action`

### Calendar
- `google-calendar-oauth-start`
- `google-calendar-oauth-callback`
- `create-calendar-event`
- `update-calendar-event`
- `classify-calendar-busy-members`
- `ensure-calendar-fresh`

## 5. Mutation receipts

All client create/state transition endpoints require `operation_id`.

Transaction:
1. compute canonical request_hash
2. select/insert receipt lock
3. existing same hash -> replay stored result
4. existing different hash -> `IDEMPOTENCY_CONFLICT`
5. business mutation
6. audit/event/outbox
7. persist result to receipt
8. commit

Receipt result does not store secrets/raw text.

## 6. LINE workers

### line-webhook-receiver
Public provider endpoint.
- signature verify
- durable inbox dedup
- fast return

### process-line-inbox
Worker-only; every minute.
- cron token verify
- queue lease
- parse text/postback
- create preview/pending action or execute explicit routine completion via normal mutation contract

### process-pending-actions
Worker-only; every minute.
- confirmed only
- lease/reclaim
- reauthorization
- DB/external side effect recovery

### send-notifications
Worker-only; every minute.
- notification outbox claim
- business TTL
- provider usage refresh when stale
- atomic quota permit before counted call
- Family Ops hard cap 200
- retry only before retry expiry
- 409 accepted reconcile
- monthly quota vs transient 429
- expired ambiguous => delivery_unknown
- quota fallback => in-app history, not dead
- reply-token interaction handled before durable counted push where applicable

## 7. Routine automation worker

### dispatch-routine-automation
Worker-only; every minute.

Responsibilities:
- evaluate fixed Asia/Tokyo local time
- calculate weekend/holiday mode
- find only applicable due `household_routine_schedules`
- resolve dropoff/pickup/non-pickup role from current task instances
- create/reuse routine sessions
- suppress empty/all-complete reminders
- bundle same-minute same-recipient sections
- claim `scheduled_dispatch_receipts`
- insert notification outbox atomically

No LINE network call directly.

### weekly preflight
Inside routine worker:
- around 10 minutes before weekly digest, enqueue active Google calendar sync with reason `weekly_digest_preflight`
- preflight claims `private.worker_run_receipts('weekly_digest_preflight', 'weekly_digest_preflight:{household_id}:{week_start}')`; duplicate claim is no-op

## 8. Google OAuth

Flow fixed: confidential web-server OAuth client + state, PKCEなし。

### start
- JWT required
- derive user/household server-side
- random 256-bit raw state
- store only SHA-256 state hash in `private.google_oauth_states`
- TTL=10m, return_to allowlisted
- scopes exactly:
  - `https://www.googleapis.com/auth/calendar.events`
  - `https://www.googleapis.com/auth/calendar.calendarlist.readonly`
- request offline access / consent as required for refresh token

### callback
- raw state hash lookup `FOR UPDATE`
- unused/unexpired state validate
- actor/household comes from state row, not callback query/client
- exchange code
- require durable refresh token on initial connection
- AES-GCM encrypt
- store household-bound Google connection
- mark state used exactly once

If refresh token unavailable in reconnection, do not overwrite known good credential with null.

## 9. Google webhook

`google-calendar-webhook`:
- provider headers validate against active/retiring channel
- valid recognized -> enqueue/coalesce sync
- unknown/stopped/expired -> 2xx ignore + structured warning

## 10. Google sync queue

### enqueue
Atomic behavior:
- no active job -> insert queued
- queued -> merge reasons, move next_attempt_at earlier if needed
- processing -> set rerun_requested true

### claim
- status queued and due OR processing stale lease reclaim
- attempts increment
- fresh lease_token

### transient failure
- processing -> queued
- exponential backoff with cap
- clear lease

### max attempts
- dead
- alert/in-app admin diagnostic

### success
- if rerun_requested false -> done
- if true -> same row queued, rerun false, next_attempt_at now, lease clear

## 11. Google sync worker

- one active per calendar
- canonical initial query exact: `singleEvents=false`, `showDeleted=true`, `maxResults=2500`, no time filters/order/q/extended filters
- canonical incremental = exact same fixed params + `syncToken`
- paginate all pages; token advancement only after success
- 410 -> all pages into `google_event_staging`, then one atomic reconcile
- nullable provider fields accepted
- rolling projection uses separate `events.list(singleEvents=true,showDeleted=false,timeMin,timeMax,orderBy=startTime,maxResults=2500)` without syncToken
- local RFC5545 parser禁止
- manual busy classification reapplied after projection rebuild
- busy member metadata parse

## 12. Google write endpoints

Writable target only:
- writerWithoutPrivateAccess
- writer
- owner
and calendar timezone Asia/Tokyo.

Create:
- deterministic remote ID
- operation receipt
- `events.insert`
- `sendUpdates='none'`

Update:
- GET current
- If-Match etag
- `events.patch` only
- owned fields only
- merge unrelated private extended properties
- no attendees/reminders/attachments unless explicitly owned
- `sendUpdates='none'`
- timeout/412 reconciliation

No full-resource update/blind overwrite.

## 13. Recurrence worker

`materialize-recurring`:
- daily 00:10 Asia/Tokyo (15:10 UTC cron)
- today..+14d
- due_at from local time + fixed Asia/Tokyo
- stable logical key
- after rule change may run targeted materialization immediately

## 14. Cleanup

Fixed retention:
- raw_inputs: configured TTL, default 24h
- used/expired line link tokens: hard delete 7d after terminal
- expired household invites: hard delete 30d after terminal/expiry
- processed webhook payload: 14d
- webhook dead metadata: 30d, redact payload after 14d
- sent notification outbox: 30d
- dead notification: 90d
- Google staging: 24h
- ordinary Google deleted tombstones: 30d
- cancelled recurring exception tombstone: retain while parent recurring event is canonical-active or until projection horizon passes exception, whichever is later
- expired/stopped watch metadata: 30d
- google_sync_jobs done: 14d
- google_sync_jobs dead: 90d
- google_write_operations succeeded/conflict: 90d
- google_write_operations dead: 180d
- line_quota_state: retain current + previous 2 months (3 months total)
- line_quota_reservations: same 3-month horizon
- pending action terminal: 30d
- pending action dead: 90d
- mutation receipts: minimum 90d; do not clean within retry/audit horizon
- scheduled dispatch receipts: 90d minimum
- worker_run_receipts: 90d

## 15. Worker token verification

All worker-only Edge Functions:
- extract `X-Family-Ops-Worker-Token`
- compare to secret constant-time
- reject missing/wrong 401 before DB claim
- never log header/token

## 16. Error envelope

```json
{
  "error": {
    "code": "IDEMPOTENCY_CONFLICT",
    "message": "同じ操作IDで異なる内容が送信されました"
  }
}
```

No secret/raw provider payload in response/log.

## 17. Household setup transaction notes

Exact create/invite/join behavior is in `18_MUTATION_CONTRACT_MATRIX.md`.
Join transaction must lock invite and household membership count and reject a 3rd active adult.
A user already belonging to any household cannot join/create another household in MVP.

## 18. LINE quota refresh

`send-notifications` treats LINE provider quota endpoints as authoritative observation:
- refresh target monthly limit + total sent usage at least every 15m while LINE outbox exists
- effective consumption=`max(provider_consumed,local_counted_success)`
- unknown/stale provider data + failed refresh => normal/reminder fallback to in-app
- hard limit hit => no LINE push API call
- 429 monthly-limit => refresh quota + fallback, never dead-letter solely for quota


## 19. Japan holiday sync

`sync-jp-holidays`:
- verify_jwt=false
- worker token
- weekly Sunday 03:00 JST
- fetch Cabinet Office CSV
- upsert `private.jp_holidays`
- partial/failure never deletes known future rows
- checked-in fixture fallback


## 20. Supabase free invocation guard

Free target 500k Edge invocations/month.
- warn 350k
- investigate 400k
- no automatic paid assumption
