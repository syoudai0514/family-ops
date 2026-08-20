# Claude Code Sonnet向け — Family Ops v5 → v6 修正依頼

対象: `family-ops-sonnet-plan-v5`

独立再レビュー結果:

**REQUEST CHANGES**  
**P0 0 / P1 8 / P2 8 / P3 2**

v5は前回のP1 8件を概ね解消済みです。
今回は追加で見つかった「実装直前の接続穴」だけを修正してください。

AI privacyはblockerにしません。
Supabaseは継続。
**v6作成後も実装は開始せず、SOL再レビューへ回してください。**

---

# P1-1 Edge Function auth matrix + config.toml

`EDGE_FUNCTION_AUTH_MATRIX.md`を新設。

Supabase Edgeはdefault `verify_jwt=true`なので以下をexact固定。

## verify_jwt=true
全user-facing mutation:
- create-household
- create-task
- send-request
- update-routine-schedule
- google-calendar-oauth-start
- その他PWA user mutations

actorはJWT subject。

## verify_jwt=false — external provider
- line-webhook-receiver
- google-calendar-webhook
- google-calendar-oauth-callback

handler内の認証:
- LINE signature
- Google watch headers/token
- OAuth state

## verify_jwt=false — worker
- process-line-inbox
- process-pending-actions
- send-notifications
- dispatch-routine-automation
- enqueue-periodic-google-sync
- renew-google-watch
- materialize-recurring
- cleanup-expired-private-data
- その他Cron-only

handler先頭で`X-Family-Ops-Worker-Token` constant-time verify。

`supabase/config.toml`のnormative snippetをpackageへ入れ、
config snapshot testを追加。

---

# P1-2 Google recurring identityを完全固定

## key functions

`originalStartTimeKey(event)`:
- all-day -> `date:YYYY-MM-DD`
- timed -> UTC normalized RFC3339 `datetime:...Z`

`occurrenceKey(event)`:
- one-off -> `event:{event.id}`
- recurring -> `rec:{event.recurringEventId}:{originalStartTimeKey}`

`classificationSubjectId(event)`:
- `event.recurringEventId ?? event.id`

Moved recurring instanceでもoriginalStartTimeをidentityにする。

Tests:
- moved instance identity unchanged
- all-day recurring
- cancelled/moved exception
- projection rebuild stable

---

# P1-3 busy classification schemaをnormalize

現在の`assigned_user_ids uuid[]`をやめることを推奨。

## public.calendar_busy_classifications
- id uuid PK
- household_id
- calendar_connection_id
- subject_event_id
- original_start_time_key nullable
- busy_scope
- created_by
- timestamps

Unique:
- partial unique `(calendar_connection_id,subject_event_id)` WHERE original_start_time_key IS NULL
- partial unique `(calendar_connection_id,subject_event_id,original_start_time_key)` WHERE original_start_time_key IS NOT NULL

## public.calendar_busy_classification_members
- classification_id
- household_id
- user_id
- PK(classification_id,user_id)
- composite FK to same-household classification/member

Add `calendar_busy_classifications` and child to RLS policy matrix.

Rules:
- SELECT same household
- mutations server-only

Tests:
- duplicate series default DB reject
- cross-HH member DB reject
- RLS cross-HH select deny

---

# P1-4 Evening recurrence setup

Fresh householdで20:00/22:00が空にならないよう、
initial setup wizardを正式仕様化。

Task definitions:
- dinner
- bath
- laundry
- dishes
- cleaning
- smile_zemi
- media_30min

各taskについてuserが:
- weekdays
- enabled/disabled
- assignee strategy:
  - nonpickup_adult
  - pickup_assignee
  - fixed
を設定。

Default proposalは`nonpickup_adult`でよいが、setupで確認して保存。

追加:
- `configure-evening-routines` mutation contract
  またはtransactional batch recurrence setup
- UI/setup acceptance
- seed/bootstrap behavior

Acceptance:
fresh setup後のconfigured weekday:
- evening task instances exist
- 20:00 nonpickup checklist non-empty
- 22:00 incomplete reminder works

---

# P1-5 LINE retry key 24h boundary

LINE retry keyはprovider側管理24h。

`notification_outbox`へ:
- provider_first_attempt_at
- provider_retry_expires_at

Rules:
- first attemptでexpiry設定（23h等margin）
- timeout/ambiguous -> same key only before expiry
- 409 same retry key -> accepted previouslyとしてsent reconcile
- expiry後にdelivery ambiguousならproviderを再callしない
- `delivery_unknown` terminal/diagnostic state
- scheduled reminderはbusiness TTLで翌日へ持ち越さない

Tests:
- retry 23h
- 409 accepted reconciliation
- >24h no provider call
- stale reminder no late delivery

---

# P1-6 LINE atomic quota permit + hard app cap 200

User requirementはfree。

ENV:
`APP_LINE_MONTHLY_HARD_CAP=200`

hard:
`min(provider_reported_limit,APP_LINE_MONTHLY_HARD_CAP)`

provider planが5000等になってもFamily Opsは200を超えてcounted pushしない。

## atomic permit

`line_quota_state.inflight_reserved`
または`private.line_quota_reservations`。

Provider call前:
1. quota row lock
2. `max(provider_consumed,local_success)+inflight_reserved`
3. priority budget check
4. one permit reserve
5. commit/hold
6. provider call

Then:
- success -> reservation convert to local_success
- definite failure -> release
- timeout ambiguous -> reservation保持
- retry uses same permit/retry key
- provider refresh reconciles

Tests:
- parallel reminder at 179
- parallel critical at 199
- provider limit 5000 still app<=200
- provider manual sends reduce available budget

`14_EXTERNAL_SETUP_STEPS`のfree plan文言も「任意」ではなくproduction gateへ。

---

# P1-7 Google write contract

## target calendar access

CalendarListEntry `accessRole`を検証。

MVP write-capable:
- writerWithoutPrivateAccess
- writer
- owner

Reject/disable:
- reader
- freeBusyReader

connection/sync-owner switch/403時にrevalidate。

## update provider method

1方式へ固定。

推奨:
- GET current event
- etag/If-Match
- PATCH only Family Ops-owned fields
- `extendedProperties.private`はexisting mapをmerge
- attendees/reminders/attachmentsは明示管理しない限り送らない
- `sendUpdates='none'` MVP default

Tests:
- reader reject
- writer roles pass
- title update preserves description/attendees/reminders
- unrelated private extended properties preserved

---

# P1-8 DDL typo

`15_DDL_CONTRACT.md`

誤:
`webhook_inbox unique(provider,event_id)`

正:
`webhook_inbox UNIQUE(provider,provider_event_id)`

03/15/migration/fixturesを同名へ統一。

contract/schema column lint test追加。

---

# P2

## 1. in-app fallback
`public.user_notifications`はnotification historyとして常にpersist。
`in_app=false`はbadge/toast等のactive presentationだけを抑止。

## 2. LINE 429
monthly-limitとtransient rate-limitをprovider responseで区別。
- monthly -> fallback
- transient -> backoff/retry same retry key within valid window

## 3. routine session A→B→A
同日assignee再変更時にold superseded session unique conflictしない方式を固定。
推奨: existing superseded session reactivate/rebuild。

## 4. scheduled_dispatch_receipts
03/15/17でexact unique constraintsを統一。

## 5. Google sendUpdates
MVP default=`none`。

## 6. Calendar timezone
Family Ops Asia/Tokyo fixedとselected calendar timezoneの差異をsetupで検出。
MVPはAsia/Tokyo calendar推奨、異なる場合warning/confirmationを固定。

## 7. R2
Backup bucketは**Standard** storage class。
usage alert/runbook追加。

## 8. Supabase free telemetry
Free Edge invocation current target 500k/monthに対し:
- warning 350k
- investigate 400k
等のrunbook/monitoringを追加。

---

# P3

1. DST/generic timezone acceptanceを残さずAsia/Tokyoへ統一。
2. SOURCE_SNAPSHOTへ2026-08-19 verified:
   - Supabase verify_jwt
   - LINE retry key 24h
   - Google Calendar accessRole
   - Google Events patch semantics
を追加。

---

# v6 output requirements

最低:
- updated README
- 01 architecture
- 03 data model
- 04 security
- 06 LINE
- 07 Google
- 09 API
- 10 WP
- 11 tests
- 12 cost
- 14 setup
- 15 DDL
- 17 routine automation
- 18 mutation matrix
- `EDGE_FUNCTION_AUTH_MATRIX.md`
- updated fixtures
- `V6_CHANGELOG.md`
- `V6_SELF_CHECK.md`
- updated `SOL_REVIEW_PROMPT.md`

Self-checkでは、
**「前レビューの指摘を文面に入れたか」だけでなく、DDL/API/test/setup間で矛盾がないか**を確認すること。

v6後は実装開始せず、SOLレビューへ。
目標: **P0=0 / P1=0 / WP1 GO**。
