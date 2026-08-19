# 10. Work Packages — v6

## WP0 — Repo / local bootstrap

Deliverables:
- repo `family-ops`
- React + TypeScript + Vite PWA
- Supabase CLI init/link
- local Supabase
- lint/typecheck/unit/integration framework
- CI
- env template
- ADR directory
- external setup checklist

Gate: **GO**

## WP1 — Core schema / Auth / RLS / mutation boundary

**WP1 migrationはv6独立SOLレビューでP0/P1=0までHOLD。**

Implement:
- households/profiles/household_members
- task definitions/subtasks with household composite keys
- recurrence rules with local time/conflict window
- task instances/events
- request lifecycle including pending-only cancel
- handovers/reads with same-household DB guarantee
- shopping state machine
- notifications/preferences
- routine schedule/session tables
- private schema
- mutation receipts
- scheduled dispatch receipts
- Google connection shell with household binding
- Google write operation shell
- queue schema/state machines
- RLS + revoke/default privileges
- Edge-only client mutation boundary
- server-only transaction RPC grants
- `btree_gist` recurrence exclusion constraint

Tests:
- RLS policy matrix
- direct RPC denial
- composite FK cross-household mutation
- operation idempotency
- recurrence overlap concurrency

SOL review gate: required.

## WP2 — Manual PWA / Today / household setup

- Google Sign-In
- household setup/invite
- initial dropoff/pickup times and weekly assignee setup
- Today hierarchy
- task create/edit/cancel/complete
- subtask contributors
- request flow
- shopping
- handover/read receipt
- notifications/preferences
- routine schedule settings screen
- offline read only

Acceptance:
AI/LINE/Calendarなしでも家庭運営できる。

## WP3 — Recurrence engine

- ISO weekday
- stable occurrence key
- scheduled local time -> due_at
- role-based assignee strategy resolver (dropoff/pickup/nonpickup)
- 14-day materializer
- once reassignment
- future todo-only rule reconciliation
- in_progress preservation
- special preparation normalized tasks
- exclusion constraint tests

SOL gate required.

## WP4 — Realtime / history

- partner realtime sync
- planned vs actual history
- handover unread
- no score/ranking
- Today refresh after partner mutation

## WP5 — Gemini

- free_lightweight parser/rewrite
- 30+ golden fixtures
- fact/quantity/date invariant validation
- manual fallback
- raw never recipient
- user-confirmed shared text

SOL gate required.

## WP6 — LINE foundation

- LINE account linking
- webhook signature
- durable webhook inbox
- pending action queue
- notification outbox
- lease/reclaim/dead-letter
- provider retry key
- natural-language commands
- PWA deep links

Tests:
- redelivery
- worker crash
- double tap
- out-of-order
- expired link

SOL gate required.

## WP7 — Google Calendar

### WP7A OAuth / connection
- separate Calendar OAuth
- household-bound credential
- AES-256-GCM refresh token
- reauth/switch owner
- production publishing status setup gate

### WP7B watch
- channel rows
- overlap renewal
- stale webhook 2xx ignore

### WP7C sync queue
- queued/processing/done/dead only
- periodic 30m
- app stale/manual trigger
- lease/reclaim/coalesce

### WP7D canonical sync
- fixed syncToken query
- nullable provider fields
- id-only deleted event
- minimal cancelled recurrence tombstone
- 410 staging/atomic commit

### WP7E projection/busy
- recurrence expansion
- transparency
- all-day exclusion
- busy member metadata
- creator/busy separation

### WP7F writes
- deterministic Google ID
- google_write_operations
- create timeout/409 recovery
- update timeout/etag/412 conflict

SOL gate required.

## WP8 — Scheduled LINE household routines

Implement `17_ROUTINE_LINE_AUTOMATION.md` exactly.

- household schedule defaults/settings
- every-minute dispatcher
- Sunday weekly digest
- weekly Google sync preflight
- 07:00 daily assignment
- 07:00 dropoff checklist bundling
- 08:30 dropoff check-in
- 16:00 pickup checklist
- 20:30 pickup check-in
- 20:00 non-pickup evening checklist
- 22:00 non-pickup check-in
- routine sessions/items
- LINE quick reply/postback
- PWA `/checkin/:sessionId`
- reminder suppression
- reassignment session supersede
- scheduled dispatch idempotency/bundling

Acceptance:
- exact scenario matrix in `fixtures/SCHEDULED_LINE_CASES.json`
- one scheduled slot => max one recipient message despite cron retry
- LINE and PWA update same canonical tasks

SOL gate required.

## WP9 — Notification UX / fatigue audit

- persistent in-app history
- calendar change/conflict messages
- notification preferences
- message copy audit
- bundle audit
- no unnecessary all-complete reminder
- no email MVP

## WP10 — Backup / recovery

- daily logical dump
- age encryption using public key in CI only
- R2 private bucket
- restore runbook
- owner-held private key
- release/monthly restore drill
- backup freshness alert

## WP11 — Production readiness

- iPhone PWA E2E
- Supabase Free pause/recovery
- Calendar OAuth In production
- LINE quota/failure
- Gemini quota/fallback
- Cron worker token rotation
- queue dead-letter runbook
- Google missed webhook convergence
- watch renewal
- cleanup
- scheduled notification timezone/idempotency
- backup freshness

## WP12 — Final independent SOL review

Fixed head/commit.
Release gate:
- P0=0
- P1=0
- empty DB migration reproducible
- all RLS/composite FK tests pass
- mutation idempotency pass
- queue crash/recovery pass
- Google schema/write/sync tests pass
- scheduled LINE matrix pass
- restore drill pass


## v6 mandatory WP1 closure

WP1 cannot GO until migration/security includes:
- auth matrix/config snapshot
- normalized busy classification tables/partial uniques/RLS
- webhook provider_event_id naming
- quota reservation schema
- LINE retry timing columns/status
- evening setup schema/mutation
- holiday cache
- contract/schema lint

WP6 LINE: parallel 179/199, cap200, retry expiry, 429 split.
WP7 Google: occurrence identity, accessRole/timezone, PATCH preservation.
WP8 Routine: fresh evening setup, A→B→A, weekend/holiday flow.
