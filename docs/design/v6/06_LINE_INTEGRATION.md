# 06. LINE Integration — v6 normative

## 1. Role

LINE is the lowest-friction input/notification channel.
PWA remains the canonical overview/settings/history UI.

LINE supports:
- natural-language add/update
- request drafting/confirmation
- handover drafting/confirmation
- shopping/ToDo add
- routine checklist delivery
- routine check-in input
- assignment-change notification
- weekly/daily digests

## 2. Account linking

- each adult links own LINE user ID to own Family Ops user
- one-time link token 256-bit, DB stores SHA-256 hash only
- TTL 10m
- single-use transactional claim
- link token never used as long-lived auth
- persistent identity is `private.line_user_links`

Claim transaction:
1. verified LINE webhook `source.userId`を取得
2. token hash row `FOR UPDATE`
3. unused/unexpired確認
4. `(household_id,user_id)` membership確認
5. `line_user_id` global uniqueness確認
6. existing user linkがunlinkedならre-link、active別IDなら拒否
7. `line_user_links`をactive化
8. token.used_at設定
9. commit

MVP invariants:
- one LINE user ID -> one Family Ops user
- one Family Ops user -> one active LINE user ID
- unlink後のみre-link可
- actorはverified `source.userId -> active line_user_links`でderive

## 3. Inbound webhook

`line-webhook-receiver`:
1. raw body signature verify
2. invalid -> reject
3. valid events persisted to `private.webhook_inbox`
4. dedup by provider + webhookEventId
5. fast 2xx
6. no Gemini/network-heavy work inline

Worker `process-line-inbox` every 1 min handles parse/action.

## 4. Natural language

Examples:
- `明日クリーニング出さないと`
- `ママに明日上履きお願い`
- `オムツAmazonで買う`
- `木曜の送り、今週だけパパにする`
- `今週から木曜の送りはママ`
- `朝、上の子が眠そうで朝ごはん少なめ`

AI/deterministic parser returns structured candidate.
Ambiguous recurrence vs once must ask confirmation.

## 5. Partner request rewrite

Raw user text:
- private only
- partner cannot read

Pipeline:
raw -> intent/facts/request/deadline extraction -> soft rewrite -> sender preview -> explicit confirm -> shared request.

AI may soften expression but must not change:
- requested action
- object/quantity
- person
- date/time/deadline
- negation

AI may not invent apology/gratitude/emotion.

## 6. Scheduled LINE

Detailed source of truth=`17_ROUTINE_LINE_AUTOMATION.md`。

User-facing default flows:

### Saturday/Sunday/holiday 09:00
Both adults receive today schedule/ToDo summary.
Sunday also includes next Monday-Sunday weekly schedule.
There is no separate Sunday 12:00 weekly push in v6.

### Saturday/Sunday/holiday 20:00
Both adults receive own incomplete-item input request.
If recipient has no actionable incomplete items, suppress that recipient message.


### Daily 07:00
Both receive dropoff/pickup assignment.
Dropoff assignee's morning checklist is bundled into same message.

### 08:30
Dropoff assignee gets check-in request only if incomplete.

### 16:00 / 20:30
Pickup assignee gets checklist then incomplete reminder.

### 20:00 / 22:00
Non-pickup adult gets own evening checklist then incomplete reminder.

## 7. LINE checklist input UX

LINE is not treated as a native persistent checkbox UI.
Use Flex/quick reply/postback actions.

Top-level:
- 全部完了
- 項目ごとに入力
- 今回は不要
- PWAで開く

Item-level:
- 完了
- 相手が対応
- 今回は不要
- 次へ

All postbacks map to the same Edge mutation contracts used by PWA.

## 8. PWA link

Every checklist/check-in message includes deep link:
`{APP_BASE_URL}/checkin/{session_id}`

No bearer credential in URL.
Supabase Auth login then return to same route.

## 9. Pending action

Natural-language create/update that changes state must preview first unless operation is low-risk deterministic completion action from a scheduled checklist.

Pending action:
- draft
- confirmed_at
- execution queue
- lease/reclaim
- business idempotency key
- expiry

Confirmation postback itself never performs external side-effect inline; it marks confirmed then worker executes.

Routine `完了` postbacks may call user mutation Edge directly because the action/resource is explicit and standard idempotency applies.

## 10. Notification outbox

LINE push is durable:
- outbox row first
- fixed provider retry key from first attempt
- retries same key
- no direct best-effort push for required scheduled notifications

Dedup:
UNIQUE(recipient_user_id, channel, dedup_key).

## 10A. Monthly free quota budget — atomic hard cap

Constants:
- `APP_LINE_MONTHLY_HARD_CAP=200`
- soft budget=180
- critical reserve=20

`effective_hard_limit=min(provider_reported_limit,200)`.

Before counted push:
1. DB transaction
2. lock current-month quota state
3. calculate `max(provider_consumed,local_counted_success)+reserved/ambiguous`
4. apply priority threshold
5. create one reservation
6. commit
7. call LINE API

Priority:
- reminder: below soft threshold only
- normal: protect critical reserve
- critical: up to hard cap

Result:
- 2xx => committed + local success increment
- 409 same retry key => accepted/reconciled + committed
- definitive failure => released
- timeout/5xx => ambiguous, retry with same request only before expiry
- retry expiry => no LINE call; `delivery_unknown`
- quota unavailable => `fallback` + in-app history

Provider usage is refreshed at least every 15m while outbox exists.
Manual OA Manager sends therefore reduce available app permits.

### 429
Do not classify all 429 as monthly quota.
- refresh provider monthly usage
- at/over effective hard limit or explicit monthly-limit error => quota fallback
- otherwise transient rate-limit => exponential backoff with same retry key within expiry

### Reply
When a current webhook reply token can satisfy the interaction, use Reply API first.
Reply messages do not consume counted monthly push allowance.

## 10B. Retry-key lifetime

Outbox fields:
- provider_first_attempt_at
- provider_retry_expires_at = first attempt + 23h safety margin
- business_expires_at

Rules:
- retry key included on first provider request
- retries keep identical recipient/body/key
- 409 accepted request => mark reconciled sent
- after retry expiry, never call provider again for ambiguous delivery
- expired scheduled reminder never delivers late

Business expiry:
- routine check-in: due+2h capped at local day end
- ordinary routine checklist/daily assignment: local day end
- nonworkday morning: 13:00 local
- nonworkday check-in: 23:00 local
## 11. Bundling

Same recipient + same scheduled local minute:
- daily assignment + dropoff checklist => one message
- different business receipts can reference same outbox message

Do not bundle messages separated by time merely to reduce volume.

## 12. Reply vs push

Immediate user interaction may use reply token if valid, but required durable state/notification cannot rely solely on reply token.
Scheduled messages use push via outbox.

## 13. Failure/recovery

- duplicate webhook -> one mutation
- process worker dies -> lease reclaim
- LINE push timeout -> same retry key
- user taps same postback twice -> mutation receipt replay
- old scheduled session superseded -> return `SESSION_SUPERSEDED` and latest PWA link
- LINE unavailable -> PWA still usable

## 14. Tests

- invalid signature
- webhook redelivery
- linked user mismatch
- raw request text never enters partner payload
- AI rewrite invariant failures rejected
- scheduled push bundling
- same scheduled slot cron twice => one push
- check-in all complete => no reminder
- quick reply double tap => one completion
- reassignment after checklist => old reminder suppressed
