# 11. Test / Acceptance — v6 normative

## 1. Release philosophy

Unit testだけでなく、壊れやすい境界をmutation/concurrency/recovery testで証明する。

## 2. Schema / RLS

Mandatory:
- household A cannot read B household/task/profile/request/shopping/handover/calendar
- cross-household assignee FK fails
- cross-household subtask completed_by fails
- cross-household handover read user fails
- cross-household Google credential binding fails
- calendar creator_mapped_user composite FK fails across household
- busy member cross-household fails
- anon direct transaction RPC execute denied
- authenticated direct transaction RPC execute denied
- valid Edge server flow succeeds
- private schema unavailable to browser roles

## 3. PWA mutation idempotency

For task create/request send/handover create/shopping add/reassign/complete:
- double tap same operation => one row/effect
- HTTP response lost then retry => same result
- concurrent same operation => one winner + replay
- same operation ID with different payload => 409 idempotency conflict

## 4. Request lifecycle

- send => pending and no task
- accept => one linked task
- concurrent double accept => one task
- decline => no task
- requester cancel pending => cancelled
- recipient cannot cancel requester request
- accepted request cannot cancel/decline
- linked task complete => request complete

## 5. Shopping

- wanted->assigned->ordered->arrived valid
- wanted->purchased valid
- assigned->wanted unassign valid
- purchased->wanted invalid
- arrived->ordered invalid
- cancelled terminal
- timestamp checks correct

## 6. Recurrence

- duplicate materializer run => one occurrence
- rule version replacement => same logical occurrence
- overlapping active range insert fails
- concurrent overlapping insert one fails
- future todo reconciles
- in_progress remains
- completed history remains
- local scheduled time -> UTC due_at correct
- Monday prep role resolves to Monday dropoff assignee
- pickup_assignee/nonpickup_adult role resolution correct
- unresolved role does not guess user

## 7. Google canonical schema

- untitled normal event saves
- deleted event containing only id/status saves/reconciles
- cancelled recurring exception with id/recurringEventId/originalStartTime saves tombstone
- occurrence does not show cancelled instance
- sync transaction succeeds and nextSyncToken advances

## 8. Google sync jobs

- transient processing error => queued + backoff
- webhook during backoff => no second active job, reason merged/rerun
- webhook during processing => rerun_requested
- success + rerun => same row queued atomically
- stale worker completion rejected by lease_token
- max attempts => dead

## 9. Google write

Create:
- backend create success + client/Edge response loss
- retry same operation => exactly one remote event
- 409 same deterministic ID => GET/reconcile
- same operation different payload => local idempotency conflict

Update:
- response loss => GET/reconcile
- remote changed => 412 path, no blind overwrite
- desired state already present => success

## 10. Busy/conflict

- pickup task has due_at from setup time
- Papa creates Mama appointment with busy_scope=mama => Mama busy only
- family event => both busy
- direct Google unknown metadata => creator not assumed busy
- transparent event ignored
- all-day ignored
- timed overlap inside ±window warns
- outside window no warning

## 11. Cron worker auth

Every worker-only endpoint:
- no token => 401
- wrong token => 401
- valid token => claim work
- token/header absent from logs/errors
- rotation test in staging/runbook

## 12. Scheduled LINE exact cases

Use `fixtures/SCHEDULED_LINE_CASES.json`.

Minimum:
1. Sunday 09:00 today + next Monday-Sunday digest to both; no Sunday 12:00 dispatch
2. Saturday/Sunday with no dropoff/pickup => no role checklist
3. 07:00 both receive assignment
4. dropoff assignee gets one bundled assignment+checklist message
5. non-dropoff adult gets assignment only
6. 08:30 fully completed => no reminder
7. 08:30 partially complete => incomplete only
8. 16:00 correct pickup assignee
9. 20:00 correct non-pickup adult
10. 20:30/22:00 incomplete reminder only
11. no evening tasks => no checklist/session
12. cron runs twice same minute => one LINE outbox per recipient bundle
13. notification worker retry => same provider retry key
14. reassignment before 16:00 changes target
15. reassignment after 16:00 supersedes old session, immediate change notice, no old 20:30 reminder
16. LINE `全部完了` then PWA open shows same completed state
17. PWA completion before reminder suppresses LINE reminder
18. old/superseded LINE button returns safe error/latest link
19. custom household schedule time sends at configured local time
20. Asia/Tokyo local-date boundary test

## 13. Weekly digest

- Monday-Sunday date boundary correct
- multi-day Google event displayed on relevant days
- special preparation included
- once reassignment reflected
- stale calendar >60m adds warning but digest still sends assignments
- Google reauth_required does not suppress household task portion

## 14. LINE

- invalid signature
- webhook redelivery
- wrong account link
- pending action confirmation replay
- quick reply/postback duplicate
- provider push timeout retry
- raw text absent from partner payload/log

## 15. AI

30+ golden fixtures.
Check:
- intent
- title
- actor/recipient
- date/deadline
- quantity
- negation
- rewrite meaning preservation
- prompt injection
- invalid schema
- AI unavailable manual fallback

## 16. PWA E2E

On iPhone-sized viewport:
- sign in
- Today
- complete task
- request send/accept
- shopping
- handover
- schedule settings
- open LINE deep link into check-in after auth
- realtime partner update
- offline mutation disabled

## 17. Backup

- backup created
- encrypted object outside Supabase
- fresh timestamp monitor
- restore into disposable database
- table counts/sample relationships/RLS migration health verified

## 18. Final acceptance gate

- lint/typecheck/tests green
- local `supabase db reset` green
- no P0/P1 review issue
- fixed head review package generated
- secrets not committed
- no force push

## v6 mandatory regression additions

### LINE free quota
- 31-day month, five Sundays, all reminders incomplete: provider-counted accepted push never > provider_limit
- effective usage >=180: reminder -> in-app fallback
- effective usage >=provider_limit-reserve: normal -> in-app fallback
- critical can consume reserve until hard limit
- hard limit: no push call
- stale/unknown quota refresh failure: normal/reminder fallback
- reply response does not increment local counted push
- provider 429 monthly limit -> fallback, not dead

### LINE identity
- one LINE id cannot link two users
- one user cannot have two active LINE ids
- re-link after unlink passes
- cross-household link fails
- unlinked verified source cannot mutate
- postback-supplied fake user id ignored

### RPC transport
- anon direct `server_tx_*` RPC denied
- authenticated direct denied
- Edge service_role pass
- private table direct browser denied

### Household setup
- concurrent join same last seat => exactly one succeeds
- third adult rejected
- user in second household rejected
- invite expired/reused rejected
- operation replay returns stable result
- same operation + different invite token => idempotency conflict

### Google OAuth state
- state expiry/reuse
- state household/user binding
- disallowed return_to rejected
- callback without browser JWT still uses bound state actor safely

### Google sync
Snapshot exact query params for initial/incremental/projection.
- syncToken query never contains timeMin/timeMax/orderBy/q/updatedMin/extended filters
- projection never contains syncToken
- 410 page2 failure keeps live cache/token
- recurring instances supplied by Google appear without local RRULE parser
- staging duplicate id deterministic

### Cross-household calendar
- Household A occurrence + Household B busy user insert fails at DB FK
- same-household busy insert passes

### Scheduler
- dispatch_slot_key exact format
- same-day schedule edit before send => one send at new slot
- same-day edit after send => no auto resend
- weekly preflight duplicate worker run => one sync enqueue

### Lifecycle/retention
- auth user hard delete is unsupported/runbook guarded
- ordinary tombstone cleanup at 30d
- google sync/write operation retention jobs use exact horizons


## v6 mandatory P1 acceptance

### Edge auth
- user no JWT => gateway 401
- LINE/Google webhook no JWT + valid provider auth => handler reached
- OAuth callback no JWT + valid state => reached
- worker valid token => pass; wrong => 401 before DB
- config snapshot matches matrix

### Google recurring/classification
- all-day/timed originalStartTime keys
- moved instance identity stable
- series default/instance override precedence
- duplicate NULL series default rejected
- cross-HH classification member rejected
- cross-HH select denied

### Evening setup
- pre-setup routine not Ready
- confirmed config materializes instances
- 20:00 weekday session non-empty when configured
- disabled absent
- pickup reassignment recalculates role-bound future work

### LINE retry
- first attempt sets retry expiry
- retry before expiry same key/body/recipient
- 409 => accepted reconcile
- after expiry => no provider call, delivery_unknown
- expired reminder not delivered next day

### Atomic quota
- parallel reminders at 179 obey soft policy
- parallel critical at 199 accepts at most one
- provider limit 5000 still app hard cap 200
- manual OA provider consumption reduces permits
- monthly vs transient 429 split

### Google write
- reader/freeBusyReader reject
- writerWithoutPrivateAccess/writer/owner pass
- non-Asia/Tokyo reject
- PATCH preserves description/attendees/reminders/attachments
- unrelated private extended properties preserved
- sendUpdates none
- 412 safe

### DDL lint
- all documented unique/FK/index columns exist
- provider_event_id spelling exact


## v6 non-workday acceptance

- Saturday 09:00 one envelope/adult
- Saturday 20:00 one envelope/adult if incomplete
- Sunday 09:00 includes next-week
- Sunday 12:00 no dispatch
- public-holiday Monday suppresses weekday role notifications
- both linked/all incomplete => max 4 counted deliveries/day
- no incomplete for one adult => suppress that person's 20:00
- holiday fetch failure + fixture date => same behavior
