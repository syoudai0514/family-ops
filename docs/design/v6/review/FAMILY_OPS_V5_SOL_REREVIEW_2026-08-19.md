# Family Ops v5 — GPT-5.6 Sol 独立再レビュー

日付: 2026-08-19  
対象: `family-ops-sonnet-plan-v5`  
判定: **REQUEST CHANGES**  
集計: **P0 0 / P1 8 / P2 8 / P3 2**

## 0. 結論

v5はこれまでで最も完成度が高い。

v4で指摘した以下はすべて概ねFIXED:
- LINE quota budget
- permanent LINE identity mapping
- private queue/token exact schema
- public service-role-only transaction RPC
- household create/invite/join
- Google OAuth state
- exact Google canonical/projection sync split
- busy-member composite FK
- Asia/Tokyo固定
- backup health簡略化
- exact OAuth scopes
- manual busy classification persistence

Supabase継続判断も変えない。

ただし、**P0/P1=0でWP1を開始するにはあと8件修正したい。**
今回は大規模な再設計ではなく、外部API実仕様とv5内部契約の最後の接続穴が中心。

---

# P1

## P1-1 Supabase Edge Functionの`verify_jwt`契約がない

### 問題

v5には以下がある:

- user-facing Edge Function
- LINE webhook
- Google Calendar webhook
- Google OAuth callback
- Cron worker-only Edge Functions

しかし`supabase/config.toml`のfunction別`verify_jwt`設定がどこにもない。

Supabase Edge Functionsは現在、**defaultで`verify_jwt=true`**。
Authorization headerにvalid Supabase JWTがなければ、handler到達前に401になる。

そのため現状のまま実装すると、少なくとも以下はJWTを持たないため動かない可能性がある:

- `line-webhook-receiver`
- `google-calendar-webhook`
- `google-calendar-oauth-callback`
- Cronからcustom worker tokenで呼ぶworker-only functions

### 必須修正

`EDGE_FUNCTION_AUTH_MATRIX.md`を追加し、`supabase/config.toml`契約まで固定。

#### user mutation functions
例:
- create-task
- send-request
- update-routine-schedule
- google-calendar-oauth-start

`verify_jwt=true`

handlerでもJWT subjectからactorをderive。

#### external provider endpoints
- line-webhook-receiver
- google-calendar-webhook
- google-calendar-oauth-callback

`verify_jwt=false`

代わりにhandler内で:
- LINE = signature
- Google watch = channel/resource/token
- OAuth callback = single-use state
を検証。

#### worker-only functions
- process-line-inbox
- process-pending-actions
- send-notifications
- dispatch-routine-automation
- enqueue-periodic-google-sync
- renew-google-watch
- materialize-recurring
- cleanup-expired-private-data

`verify_jwt=false`

handler冒頭で`X-Family-Ops-Worker-Token`をconstant-time verifyしてからDB access。

### Tests
- LINE webhook: no Supabase JWTでもsignature validならhandler到達
- Google webhook: no JWTでもvalid watchなら到達
- OAuth callback: no JWTでもvalid stateなら到達
- worker: no JWT + valid worker token => pass
- worker: wrong token => 401
- user mutation: no JWT => gateway 401
- config.toml snapshot test

---

## P1-2 Google recurring occurrence identity / manual classification keyが未定義

### 問題

`calendar_event_occurrences.occurrence_key`は存在するが、生成式がない。

Google recurring instanceでは:
- `recurringEventId` = parent series ID
- `originalStartTime` = recurrence上の元の開始時刻
- `originalStartTime`はinstanceが移動してもseries内でinstanceを一意に識別する

したがってactual `start`やprojection event IDだけでidentityを組むと、
移動されたinstanceのmanual classificationを安定保持できない。

さらに`calendar_busy_classifications`は:
- `google_event_id`
- nullable `original_start_time_key`

を持ち、
`null => event/series default`
としている。

しかしprojection instanceの`google_event_id`はseries parent IDとは別なので、
どのIDを「series default」に使うのか未定義。

### 必須修正

#### `original_start_time_key`
exact canonical encodingを固定。

例:
- all-day: `date:2026-08-19`
- timed: `datetime:2026-08-19T01:30:00Z`

timedはRFC3339をUTC normalize。

#### occurrence_key
- one-off: `event:{google_event_id}`
- recurring: `rec:{recurring_event_id}:{original_start_time_key}`

#### classification subject
`subject_event_id = recurring_event_id ?? google_event_id`

- series/event default:
  `(calendar_connection_id, subject_event_id, original_start_time_key=NULL)`
- one occurrence override:
  `(calendar_connection_id, subject_event_id, original_start_time_key=<key>)`

Priority:
instance override > series/event default > Family Ops metadata > unknown

### Tests
- moved recurring instance keeps same occurrence identity
- series classification applies to all future instances
- one instance override wins
- all-day originalStartTime stable
- rebuild does not lose classification

---

## P1-3 `calendar_busy_classifications`のDB integrity / RLSが未完成

### 問題A: nullable UNIQUE

現在:
`UNIQUE(calendar_connection_id,google_event_id,original_start_time_key)`

Postgresの通常のUNIQUEではNULL同士はdistinct。
したがって`original_start_time_key=NULL`のseries defaultを複数row作れる。

### 問題B: RLS matrix missing

`fixtures/RLS_POLICY_MATRIX.md`に、
新規`public.calendar_busy_classifications`が存在しない。

### 問題C: `assigned_user_ids uuid[]`

array要素へ通常FKを付けられない。
現在は「transaction + DB helper/check test」としか固定されておらず、
DBがcross-household userを拒否するexact mechanismが未定。

### 必須修正

最も明快なのはnormalization。

#### public.calendar_busy_classifications
- id
- household_id
- calendar_connection_id
- subject_event_id
- original_start_time_key nullable
- created_by
- timestamps

Unique:
- partial unique `(calendar_connection_id,subject_event_id) WHERE original_start_time_key IS NULL`
- partial unique `(calendar_connection_id,subject_event_id,original_start_time_key) WHERE original_start_time_key IS NOT NULL`

#### public.calendar_busy_classification_members
- classification_id
- household_id
- user_id
- PK(classification_id,user_id)
- composite FK `(household_id,user_id)` -> household_members
- composite relationshipでclassification household整合性も保証

RLS:
- SELECT = same household
- INSERT/UPDATE/DELETE = server-only
をmatrixへ追加。

### Tests
- duplicate series default DB reject
- cross-HH assigned user DB reject
- browser cross-HH SELECT deny
- authenticated direct mutation deny

---

## P1-4 夜タスクのrecurrence setupがなく、20:00/22:00 routineが空になり得る

### 問題

`INITIAL_TASK_SEED.yaml`には:

- dinner
- bath
- laundry
- dishes
- cleaning
- smile_zemi
- media_30min

のtask definitionsがある。

しかしrecurrence_rulesは:
- dropoff
- pickup
- Monday/Tuesday/Thursday preparation

だけ。

コメントでも:
`evening task assignees are not guessed by seed`

となっている。

一方、製品コア要件は:
- 20:00 non-pickup evening checklist
- 22:00 check-in

である。

`14_EXTERNAL_SETUP_STEPS`には「evening task assignmentsを聞く」とあるが、
どのscreen / mutation / rule creation contractでrecurrence_rulesを作るかがない。

このままfresh installすると:
- scheduleだけ20:00/22:00 enabled
- 対象task instanceは0
- empty session suppression
- **LINEは何も送られない**
となり得る。

### 必須修正

初回setup wizardへ「夜タスク担当設定」を正式追加。

各evening task definitionについて最低:
- enabled weekdays
- assignee strategy:
  - pickup_assignee
  - nonpickup_adult
  - fixed
  - disabled
- optional scheduled_local_time

ユーザーの希望する「お迎え担当外に20時 checklist」を成立させるため、
MVP default candidateは対象夜タスクに`nonpickup_adult`を提示してよい。
ただし初期setupで夫婦が確認して保存する。

mutation:
`configure-evening-routines`
または既存`change-recurrence`をsetup transactionとしてbatch化。

### Acceptance
fresh household setup完了後:
- configured weekdayにevening task_instancesが存在
- 20:00 nonpickup session is non-empty
- 22:00 incomplete reminder works
- disabled task is absent
- reassignment/pickup change recomputes role-based future todo correctly

---

## P1-5 LINE retry idempotencyが24時間境界を扱っていない

### 問題

v5:
- provider_retry_keyを作成
- initial push / retriesは同じ`X-Line-Retry-Key`
- timeout後も同key

これは24時間以内なら正しい。

しかしLINE公式では、retry keyの管理期間は**24時間**。
24時間を超えて同じkeyを使うとnew requestとして扱われ、
既に成功済みでもduplicate messageが送られ得る。

v5には:
- first provider attempt time
- retry key expiration
- retry max age
がない。

### 必須修正

notification_outboxへ:
- provider_first_attempt_at
- provider_retry_expires_at

初provider attempt:
`retry_expires_at = first_attempt + 23h` 等、安全margin込み。

Rules:
- ambiguous timeout/5xxは同keyでexpiryまでretry
- 409 same retry key = prior request acceptedとしてsent reconcile
- expiry後にprovider結果不明なら**LINEへ再送しない**
- `delivery_unknown` terminal or diagnostic stateへ
- PWA/in-appへ状態を残す
- scheduled reminderはそもそも短いbusiness TTLでexpireさせる

### Tests
- timeout -> 23h以内retry => same key
- accepted duplicate 409 => sent
- 24h以降 => LINE APIを呼ばない
- late reminder is not sent next day

---

## P1-6 LINE無料枠のquota reservationが非atomic + 「無料プラン」がhard gateでない

### 問題A: race

現在:
1. `effective_consumed=max(provider_consumed,local_counted_success)`
2. check
3. LINE API
4. success後にlocal counter increment

複数worker/claimが並行すると:
- 179でnormal/reminder複数が同時に179を読む
- 両方送信
- soft budget/reserveを意図以上に消費

199でcriticalが2本並行した場合、
LINE provider自体のhard quotaが最終的には止めるが、
Family Opsの「20通critical reserve」をDB上では数学的に保証していない。

### 問題B: free plan is conditional

setup:
`Communication Plan/free運用を使う場合`

となっている。

ユーザー要件は**無料運用**。
誤ってLight/Standard等へ変えた場合、
dynamic `provider_limit`を使う現在設計ではFamily Ops自身が200超送信を許可し得る。

### 必須修正

#### hard app cap
`APP_LINE_MONTHLY_HARD_CAP=200`

`effective_hard_limit=min(provider_reported_limit, APP_LINE_MONTHLY_HARD_CAP)`

production readiness:
- provider limit unexpected => warning/fail safe
- Family Opsから200を超えてcounted pushしない

#### atomic permit/reservation
`private.line_quota_state`へ:
- inflight_reserved int
またはreservation table。

Provider call前にrow lock/atomic functionで1 permitをreserve。

decision:
`max(provider_consumed,local_success) + inflight_reserved`

- success => reservation -> local_success
- definitive failure => release
- timeout/ambiguous => reservation保持してretry/reconciliation
- provider usage refreshでreconcile

### Tests
- consumed=179でparallel reminders => soft-budget invariant
- consumed=199でparallel critical => <= hard cap
- provider plan limit 5000でもapp sends <=200
- manual Official Account Manager usage captured by provider consumption
- stale provider usage => reminder/normal fallback

LINE公式のcurrent Japan Communication Planは200/月で、超過時はmessage send error。
このアプリ側capは将来プラン変更時にも「無料」を守るための追加防御。

---

## P1-7 Google Calendarのwrite contractが未完成

### 問題A: calendar accessRole

OAuth後calendar listからtargetを選ぶが、
選択calendarがwrite可能かを検証するcontractがない。

現在のGoogle Calendar `accessRole`:
- freeBusyReader
- reader
- writerWithoutPrivateAccess
- writer
- owner

readerを選ぶとsyncはできてもFamily Opsのcreate/updateは失敗する。

### 問題B: update method ambiguity

18では:
`desired patch`
と書くが、
provider callが:
- `events.patch`
- `events.update`
のどちらか未固定。

Google `events.patch`はpartial semantics。
`events.update`はfull update前提。

誤ってdesired patchを`events.update` bodyとして送ると、
Family Opsが管理していないevent fieldを消す危険がある。

### 必須修正

#### target calendar eligibility
target selectionではwrite-capable roleだけ:
- writerWithoutPrivateAccess
- writer
- owner

をMVPで許可。
reader/freeBusyReaderはdisabled表示。

connection時・sync owner変更時・403時にrevalidate。

#### update method
1方式へ固定。

推奨:
1. GET current event
2. If-Match/etag verify
3. Family Ops-owned fieldだけmerge
4. `events.patch`またはmerged full `events.update`のどちらかへ固定

簡潔さとデータ保護ならPATCHを採用してよいが、
array fieldは指定すると全体置換になるため注意。

特に:
- extendedProperties.privateは既存private mapをmerge
- attendees/reminders/attachmentsはFamily Opsが管理しないならbodyへ入れない
- `sendUpdates='none'`もMVP defaultとして固定推奨

### Tests
- reader calendar rejected
- writerWithoutPrivateAccess/writer/owner accepted
- title update doesn't erase description
- title update doesn't erase attendees/reminders
- unrelated extendedProperties.private remains
- 412 remains no-blind-overwrite

---

## P1-8 DDL contractとdata modelのcolumn名不整合

### 問題

`03_DOMAIN_AND_DATA_MODEL.md`:
`private.webhook_inbox.provider_event_id`

正しいunique:
`UNIQUE(provider,provider_event_id)`

一方`15_DDL_CONTRACT.md`:
`webhook_inbox unique(provider,event_id)`

`event_id`というcolumnは存在しない。

normative DDL contractをそのままSQLへ落とすとmigrationで事故る。

### 必須修正

15を:
`webhook_inbox UNIQUE(provider,provider_event_id)`
へ統一。

さらにcontract lint testを追加:
- DDL contractに書かれたcolumn名がmodel/schema SQLに存在する
- fixture key namingも一致

これは修正自体は1行だが、WP1 migration正本の誤りなので実装前修正を要求する。

---

# P2

## P2-1 `notification_preferences.in_app=false`時のquota fallback semantics

LINE quota fallback時は`public.user_notifications`へ残す、とv5は書く。
一方userはin_app notificationをoffにできる。

推奨:
- `user_notifications`は**履歴/受信箱として常にpersist**
- `in_app=false`はactive badge/toast表示を抑止するだけ
- quota fallbackだけは設定画面に「LINEに送れなかったためアプリ内保存」と表示可能

履歴まで捨てる設計にしない。

## P2-2 LINE 429をmonthly quotaとgeneric rate limitで区別

v5:
`provider 429/monthly-limit => fallback`

429には月次quota以外のrate/routing制限もあり得る。

provider error body/codeをparse:
- monthly limit => fallback + quota refresh
- transient rate limit => backoff/retry same retry key within 24h
へ分離。

## P2-3 routine sessionのA→B→A同日再assign

UNIQUE:
`(hh,session_type,date,assignee_id)`

A session作成 -> Bへreassign -> Aへ戻す場合、
古いA session rowがsupersededのまま存在する。

新A session insertはunique conflict。

解決:
- same assignee existing superseded sessionをreactivate/rebuild
または
- assignment_generationをuniqueへ含める

1方式へ固定。

## P2-4 scheduled dispatch receipt uniqueが文書間で二重

03:
slot key込みuniqueのみ。

15/17ではsemantic duplicate guardも追加されている箇所がある。

normative SQLではexact constraintsを1セットに統一する。
特にsame-day schedule version change semanticsと矛盾させない。

## P2-5 Google `sendUpdates`を固定

Family Opsが共有calendarへhousehold-owned eventを書くだけなら、
不要なGoogle招待メールを避けるためMVP default:
`sendUpdates='none'`
を推奨。

attendee notification featureは将来。

## P2-6 Selected Google Calendar timezone check

Family Ops MVPはAsia/Tokyo固定。

target calendarが別timezoneの場合:
- all-day
- projection window
- displayed local day
で混乱する。

MVP setup:
- calendar timezoneがAsia/TokyoならOK
- 異なる場合warning + confirm、またはMVPではreject

どちらか固定。

## P2-7 R2 free targetをStandard storageへ固定

Cloudflare R2のfree tierは現在Standard storageに適用され、
Infrequent Accessには適用されない。

Backup bucket setup:
- Standard storage
- storage/operations usage alert
を明記。

Family Opsの小規模encrypted dumpなら現行free tier
10 GB-month / 1M Class A / 10M Class B
に十分収められる見込み。

## P2-8 Supabase invocation budget telemetry

現在Cron:
- 4 worker x every minute = 約172,800 calls / 30-day month
- plus 30m sync / 6h renewal / daily jobs / user/webhooks

Supabase Free Edge Function quotaは現在500,000 invocations。

現状は十分余裕があるが、無料保証のため:
- monthly Edge invocation metric
- warn at 350k
- investigate at 400k
程度のrunbookを入れる。

---

# P3

## P3-1 timezone test stale wording

v5はAsia/Tokyo固定、DST generic out of scope。
11_TESTにgeneric timezone conversionの古い表現が残る場合はAsia/Tokyo testへ統一。

## P3-2 source snapshotに外部仕様確認日を更新

今回追加で依存する:
- Supabase Edge `verify_jwt`
- LINE retry key 24h
- Google Calendar accessRole
- Google Events patch semantics
をSOURCE_SNAPSHOTへ2026-08-19 verifiedとして追加。

---

# 2. v4 P1再確認

| v4 review item | v5 result |
|---|---|
| LINE monthly quota budget | PASS, atomic reservation/hard app cap補強要 |
| LINE identity mapping | PASS |
| private exact schema | PASS |
| Edge -> public server RPC | PASS |
| household setup mutation | PASS |
| Google OAuth state | PASS |
| exact canonical/projection/staging | PASS |
| busy-member composite FK | PASS |

つまり前回指摘8件を“放置”しているわけではない。
今回のP1は、v5をさらに実装直前まで検証して見つかった新規残件。

---

# 3. 無料構成再判定

## Supabase
**継続推奨。**

Free Edge Function quotaは現在500,000 invocations/月。
v5の固定Cronだけなら概算約173k/月 + その他で、家庭2人用途では十分現実的。

## LINE
**200通hard app cap + atomic permitを入れれば無料運用をかなり強く保証できる。**

Communication Planは現在200通/月。
reply messagesはcount対象外。
push等はcount対象。
quota超過時は送信error。

## Cloudflare R2
Backup用途はStandard storageでFree target可能。
現行free tier:
- 10 GB-month
- Class A 1M/month
- Class B 10M/month
- Internet egress free

DB本体をCloudflare D1へ移す理由は依然ない。

---

# 4. 実装開始判定

## WP0
**GO**

## WP1
**HOLD — v6のP1修正後にGO**

理由:
- Edge Function gateway auth
- Google classification schema
- evening recurrence setup
- DDL typo
がWP1/schema/setupへ直接影響する。

ただし、v6は大規模改修不要。
今回の8件をv5へpatchするだけでよい。

---

# 5. 最終評価

v5の設計はかなり高品質。
今回もREQUEST CHANGESだが、性質は明確に「最後の実装契約補完」。

優先順位:

1. Edge Function auth matrix / config.toml
2. Google recurring identity + busy classification DB schema
3. evening recurrence initial setup
4. LINE retry 24h + atomic quota permit + app hard cap 200
5. Google writable calendar/update semantics
6. DDL provider_event_id typo

v6では**P0=0 / P1=0を目標にしてよい**。

---

# 6. External source snapshot (verified 2026-08-19)

- Supabase Edge Function Configuration / Authorization headers:
  https://supabase.com/docs/guides/functions/function-configuration
  https://supabase.com/docs/guides/functions/auth-headers
- LINE Messaging API pricing / retry:
  https://developers.line.biz/en/docs/messaging-api/pricing/
  https://developers.line.biz/en/reference/messaging-api/
- Google Calendar Events list / recurring events / CalendarList / Events patch:
  https://developers.google.com/workspace/calendar/api/v3/reference/events/list
  https://developers.google.com/workspace/calendar/api/guides/recurringevents
  https://developers.google.com/workspace/calendar/api/v3/reference/calendarList
  https://developers.google.com/workspace/calendar/api/v3/reference/events/patch
- Cloudflare R2 pricing:
  https://developers.cloudflare.com/r2/pricing/
