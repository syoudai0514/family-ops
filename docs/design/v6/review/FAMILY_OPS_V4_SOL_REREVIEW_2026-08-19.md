# Family Ops v4 — GPT-5.6 Sol 独立再レビュー

日付: 2026-08-19
対象: `family-ops-sonnet-plan-v4`
判定: **REQUEST CHANGES**
集計: **P0 0 / P1 8 / P2 7 / P3 3**

## 0. 前提

- AI privacy論点はユーザー判断でblockerにしない。
- Supabase継続方針は維持。
- 「無料運用」は明示要件として扱う。
- v3レビューで指摘した主要10件はv4でほぼ正しく反映済み。
- 今回はv4単体を実装正本として、Sonnetが追加設計判断なしに実装できるかを横断確認した。

---

# 1. 総評

v4はこれまでで最も完成度が高い。

前回P1は以下すべて概ねFIXED:
- Google untitled/deleted/cancelled nullable contract
- deterministic Google event ID
- google_write_operations
- google_sync_jobs state machine
- Edge-only mutation entry
- mutation receipt
- Cron worker token
- recurrence scheduled time
- busy-person model
- transparency handling

特にGoogle event ID:
`fo + UUID lowercase hex without hyphens`
はGoogle Calendarのevent ID許容文字（base32hex subset）に収まり、長さも問題ない。

しかしv4で追加された定時LINE運用を含め、実際に全体をつなぐとまだ8件のP1が残る。

**最大の新規問題はLINE無料枠。**
現在の日本のLINE Official Account無料プランは月200通。
v4のscheduled pushは最大ケースでそれだけで200を超える。

---

# P1

## P1-1 LINE無料200通をscheduled pushだけで超え得る

### 事実

日本のLINE Official Account Communication Plan:
- 月額0円
- 無料メッセージ 200通/月
- 追加メッセージ不可

Messaging APIでは:
- push / multicast / broadcast / narrowcastはcount対象
- reply messageはcount対象外
- quota超過後はsend error

### v4 defaultの最大push数

31日・日曜5回の月:

- weekly digest: 5回 x 2人 = 10
- daily assignment: 31 x 2人 = 62
- 07:00 dropoff checklist: dropoff担当はdaily assignmentへbundle済みなので追加0
- 08:30 dropoff check-in: 最大31
- 16:00 pickup checklist: 31
- 20:30 pickup check-in: 最大31
- 20:00 non-pickup checklist: 31
- 22:00 non-pickup check-in: 最大31

**合計最大 227通/月**

しかもこれに:
- request通知
- reassignment通知
- conflict通知
- shopping/handover
が追加される。

28日・日曜4回でも全reminder発生なら:
8 + 56 + 28 + 28 + 84 = **204通**。

したがって「完了済みreminderは抑止するからたぶん200以内」では、
無料要件を保証できない。

### 必須修正

`send-notifications`へLINE quota budgetを正式導入。

推奨:

### private.line_quota_state
- billing_month date PK（月初）
- provider_limit int
- provider_consumed int
- local_counted_success int
- last_provider_refresh_at timestamptz
- updated_at

### notification_outbox追加
- priority check (`critical`,`normal`,`reminder`)
- quota_fallback_allowed bool

### policy
- providerのquota/consumption APIを定期取得
- soft budget = 180
- reserve = 20
- hard limit = provider reported limit
- reminderはsoft budget超過時LINE送信せずin-appへfallback
- normalはreserveを状況に応じ使用
- criticalはhard limitまで使用
- hard limit到達後は全てin-app
- quota exhaustionをdead queue扱いしない
- provider quota refreshが古い/不明なら安全側へ倒す

### priority例
critical:
- same-day assignment change
- direct partner request

normal:
- daily assignment
- pickup/nonpickup checklist
- weekly digest

reminder:
- 08:30
- 20:30
- 22:00 check-in

immediate interactive bot responseはreply tokenが有効ならreply messageを優先し、push quotaを消費しない。

### Tests
- 31日全reminder未完了でもcounted push <= provider limit
- soft budget後reminderはin-app
- hard limit後push attemptなし
- provider consumption refresh
- reply response does not consume local push budget
- request critical reserve works

---

## P1-2 LINE user ID -> Family Ops user の永続mapping tableが存在しない

### 問題

文書には:
- 各adultがLINE user IDをlink
- webhookのverified LINE user IDからinternal actorをderive

とある。

しかしv4 data modelに、
**link後のLINE identity mapping tableが存在しない。**

`line_link_tokens`は一回限りtokenであって、
永続identity mappingではない。

このままではwebhook受信後に:
`LINE user Uxxxxxxxx -> auth user UUID`
を解決できない。

### 必須修正

`private.line_user_links`

推奨:
- id uuid PK
- household_id uuid not null
- user_id uuid not null
- line_user_id text not null
- status check (`active`,`unlinked`)
- linked_at timestamptz
- unlinked_at timestamptz null
- created_at / updated_at
- UNIQUE(user_id) for MVP
- UNIQUE(line_user_id)
- composite FK `(household_id,user_id)` -> household_members

Link token claim transaction:
1. token hash lock
2. internal user/household load
3. LINE user id uniqueness check
4. line_user_links upsert/create
5. token used_at set
6. commit

Webhook actor:
verified source.userId -> active line_user_links -> internal user。
client/postback payload内user IDはactor根拠にしない。

Tests:
- one LINE user cannot link two Family Ops users
- one Family Ops user cannot have two active LINE ids in MVP
- unlinked user webhook cannot mutate
- re-link after unlink
- cross-household link rejected

---

## P1-3 Critical private LINE/security tablesがv4単体で定義されていない

### 問題

`03_DOMAIN_AND_DATA_MODEL.md` は以下を:
`Other existing private tables retained`
とだけ書く。

- webhook_inbox
- pending_actions
- raw_inputs
- household_invites
- line_link_tokens

しかしv4 package単体にはnormative column definitionがない。

DDL contractには一部unique/indexだけあるが、
Sonnetが以下を決める必要が残る:
- PK
- status enum
- actor/household binding
- payload
- operation_id
- lease fields
- TTL
- used/confirmed/executed timestamps
- same-household FK

これは「実装時の設計判断を残さない」というpackage方針に反する。

### 必須修正

03/15へ全table exact schemaを戻す。

最低:

#### private.webhook_inbox
- id
- provider
- provider_event_id
- source_external_user_id nullable
- payload jsonb
- status received/processing/done/dead
- attempts
- next_attempt_at
- lease_owner/token/until
- last_error
- received_at/processed_at
- UNIQUE(provider,provider_event_id)

#### private.pending_actions
- id
- household_id
- actor_id
- source
- action_type
- normalized_payload
- operation_id
- status draft/confirmed/queued/executing/succeeded/cancelled/expired/dead
- confirmed_at
- expires_at
- attempts/next_attempt
- lease fields
- result reference
- same-household actor FK

#### private.raw_inputs
- id
- household_id
- author_user_id
- kind
- raw_text or raw_payload
- expires_at
- created_at
- same-household author FK

#### private.household_invites
- token_hash unique
- household_id
- created_by
- expires_at
- used_at/used_by
- created_at

#### private.line_link_tokens
- token_hash unique
- household_id
- user_id
- expires_at (10m)
- used_at
- created_at

---

## P1-4 Edge -> `private.tx_*` RPC invocation pathが現在の記述では矛盾

### 問題

v4:
- transaction RPC例=`private.tx_create_task`
- private schemaはData APIへ露出しない
- Edgeがserver-only transaction RPCをcall
- Supabase Edgeから通常supabase-js RPC利用を想定

Supabase Data APIからcustom schemaのfunctionをcallするには、
そのschemaをExposed Schemasへ追加する必要がある。

したがって:
**private schemaを非公開のまま、Data API経由でprivate RPCをcall**
はそのままでは成立しない。

Edgeからdirect Postgres connectionを使う手はあるが、
v4はどちらを使うか固定していない。

### 必須修正 — 1方式に固定

MVP推奨:
**server transaction RPC entrypointはpublic schemaへ置く。**

例:
- `public.server_tx_create_task`
- `public.server_tx_accept_request`

Security:
- `REVOKE EXECUTE FROM PUBLIC, anon, authenticated`
- `GRANT EXECUTE TO service_role`
- Edgeのみservice-role supabase clientでcall
- SECURITY INVOKER
- underlying private schema USAGE/table permissionはservice_roleのみ
- browser rolesはprivate schema accessなし

内部helperはprivate schemaに残してよい。

これなら:
- private tablesはData API非公開
- Edgeは通常のsupabase-js RPCでatomic DB transactionを利用
- clientはEXECUTE privilegeで拒否
が同時成立する。

Tests:
- authenticated supabase.rpc direct -> permission denied
- anon direct -> denied
- service role Edge -> pass
- private table direct browser -> denied

---

## P1-5 Household setup mutation contractが18に存在しない

### 問題

09は以下endpointを必須としている:
- create-household
- create-household-invite
- join-household

しかしnormative `18_MUTATION_CONTRACT_MATRIX.md` にcontractがない。

特にjoinは:
- userが既に別HHへ所属
- invite expired/reused
- concurrent claim
- household member count
- membership/profile作成
をtransactionally決める必要がある。

### 必須修正

18へ追加。

#### create-household
- JWT user
- operation_id
- caller not existing member
- household + membership + profile bootstrap atomic
- receipt replay

#### create-household-invite
- caller HH member
- operation_id
- random 256-bit raw token
- DBはhash only
- TTL固定（推奨24h）
- return raw token only once

#### join-household
- JWT user
- operation_id
- raw token hash
- unused/unexpired lock
- caller not already in HH
- MVP max adult=2
- membership create
- token used_at/used_by
- one transaction

Tests:
- concurrent join
- second household denied
- third adult denied
- replay returns prior result
- same operation different token conflict

---

## P1-6 Google OAuth `state` storage/replay contractがない

### 問題

09:
- generate state
- state server stored/validated

しかしstate tableがない。

Google OAuthではstateはCSRF防止の重要値。
callback時には通常ブラウザJWTが必ずあるとは限らないため、
state自身を:
- user
- household
- expiry
へbindする必要がある。

### 必須修正

`private.google_oauth_states`

- state_hash text PK
- household_id uuid
- user_id uuid
- return_to text nullable (allowlist)
- created_at
- expires_at
- used_at nullable
- composite FK household/user

Flow:
1. authenticated start
2. random non-guessable state生成
3. hashだけDB保存
4. raw stateをGoogle authorization URLへ
5. callback hash lookup + lock
6. unused/unexpired + expected redirect/client check
7. code exchange
8. used_at set
9. reuse reject

TTL推奨10分。

PKCEを採用するならcode_verifierもencrypted/private保存。
採用しないならv4/v5で「web-server confidential client + state、PKCEなし」と固定し、Sonnet判断に残さない。

---

## P1-7 Google canonical sync / occurrence projectionのexact query contractと410 staging schemaがまだ未固定

### 問題A: canonical query

v4は:
`fixed events.list syncToken contract`
と書くが、初回のactual parametersがない。

GoogleはsyncToken利用時:
- timeMin/timeMax/orderBy/q等を併用不可
- showDeleted=false不可
- その他parameterはinitial syncと同じにするよう要求

### 問題B: projection方式

v4:
`projection handles recurrence expansion`
とあるだけで、

- Family OpsでRFC5545をlocal expand
- events.instances
- events.list(singleEvents=true)

のどれを使うか未固定。

これは実装量/正しさが大きく違う。

### 問題C: staging

`private.google_event_staging per sync_run_id`
しか定義がなく、
atomic 410 reconcileに必要なcolumn/unique/keyが不明。

### 必須修正

#### Canonical
1方式へ固定:

Initial:
- `events.list`
- `singleEvents=false`
- `showDeleted=true`
- `maxResults=2500`
- timeMin/timeMaxなし
- orderBy/q/privateExtendedProperty/sharedExtendedPropertyなし
- 全page
- nextSyncToken保存

Incremental:
- same fixed params
- syncToken追加
- 全page
- token advancement only end

#### Rolling projection
**local recurrence parserを実装しない。**

別query:
- `events.list`
- `singleEvents=true`
- `showDeleted=false`
- `timeMin=windowStart`
- `timeMax=windowEnd`
- `orderBy=startTime`
- `maxResults=2500`
- pagination
- syncTokenは使わない

これによりGoogle側にrecurring instance展開を任せる。

#### staging
`private.google_event_staging`
- sync_run_id uuid
- calendar_connection_id uuid
- google_event_id text
- event_json jsonb
- received_at
- PK(sync_run_id,google_event_id)
- index(calendar_connection_id,sync_run_id)

Full sync:
- all pages staging
- complete only after final page/nextSyncToken
- one DB transactionでlive reconcile + sync token更新
- failure時staging delete/TTL cleanup

Tests:
- exact query snapshot
- accidental timeMin with syncToken rejected by unit contract
- recurring master absent from projection but instances present
- moved/cancelled exceptions
- 410 page2 failure leaves old live
- staging duplicate id upsert deterministic

---

## P1-8 `calendar_occurrence_busy_members`にcross-household FK holeが残る

### 問題

busy_members:
- household_id
- calendar_connection_id
- occurrence_key
- user_id

現在:
- `(household_id,user_id)` -> household_members
- `(calendar_connection_id,occurrence_key)` -> occurrence

しかし:
`household_id + calendar_connection_id`
を同一householdと保証するcomposite FKがない。

理論上:
- occurrence/calendar = Household A
- busy_members.household_id = Household B
- user_id = Household B user
というrowがDBで成立し得る。

service bug時にcross-household inconsistent rowを作れる。

### 必須修正

Occurrence:
- add `UNIQUE(household_id,calendar_connection_id,occurrence_key)`

busy_members:
- composite FK
  `(household_id,calendar_connection_id,occurrence_key)`
  -> calendar_event_occurrences(household_id,calendar_connection_id,occurrence_key)

さらに:
- `(household_id,calendar_connection_id)`
  -> calendar_connections
は上記FKで実質保証できるため重複不要。

Tests:
- A occurrence + B household/user insert fails
- same-HH classification passes

---

# P2

## P2-1 `materialize-recurring`の「daily 00:10 household timezone」を単一Cronでどう実行するか不明

`household.timezone`は可変、DST generic testもあるが、
pg_cron固定時刻はhouseholdごとに変わらない。

Family Opsが日本家庭専用MVPなら最も簡単なのは:
- MVP timezoneをAsia/Tokyo固定
- 15:10 UTC Cron
- generic DST testを削除

multi-timezoneを残すなら:
- every 10m Cron
- workerが各HH local time 00:10 slotを判定
- `materialization_receipt(hh,local_date)`で1日1回保証

どちらかへ固定。

## P2-2 google_sync_jobs / google_write_operations retentionがない

periodic sync 30分ならdone jobが年約17,500 rows/connection増える。

追加:
- google_sync_jobs done 14d
- dead 90d
- google_write_operations succeeded/conflict 90d以上（mutation receipt horizon以上）
- dead 180d optional

cleanup contractへ。

## P2-3 `backup-health-check`のhealth sourceが存在しない

Supabase Cronが06:00にbackup freshnessを見るとあるが、
backupはGitHub Actions -> R2。

DBにbackup run heartbeat/table/APIがないため、
何を見てfreshness判定するのか未定義。

MVP推奨は簡略化:
- Supabase `backup-health-check` Cronを削除
- GitHub Action自身でR2 upload HEAD/size/hash確認
- Actions failure notification
- monthly manual restore drill

in-app backup warningが必須なら`private.backup_runs` + signed reporting endpointを別途定義。

## P2-4 Google Calendar OAuth scopesをexact固定

PWAでcalendar listから対象を選び、event read/write/watchするなら推奨:
- `https://www.googleapis.com/auth/calendar.events`
- `https://www.googleapis.com/auth/calendar.calendarlist.readonly`

必要以上にfull `calendar` scopeを取らない。
Setup/consent testでexact scope setをassert。

## P2-5 manual busy classificationのpersist scopeを固定

Direct Google eventをPWAで「パパの予定」等に分類した場合:
- occurrence単位か
- recurring series全体か
- future projection refresh時どう保持するか
が不明。

MVP推奨:
- classification key = calendar_connection_id + google_event_id
- optional original_start_time for instance override
- separate persistent `calendar_busy_classifications`
- projection refreshがmanual classificationを再適用
- occurrence table rebuildでmanual mappingを失わない

## P2-6 Auth user deletionとhistorical FK RESTRICTの関係を明記

auth user -> household_members CASCADEだが、
多数のhistorical rowがhousehold_membersをRESTRICT参照する。

結果としてauth user hard deleteが失敗し得る。

MVP:
- account/member hard deleteをサポートしない
- membership active/inactive soft stateを将来用に用意するか
- setup/runbookでauth user deletion禁止
を明記。

## P2-7 MVP adult=2をjoin transactionで保証

非pickup role等はadult 2名を前提にする。
UIでerrorだけでなくjoin transactionで:
- current active adult count <2
をlock/check。
3人目invite claimを拒否。

---

# P3

## P3-1 ordinary deleted tombstone retentionがまだ選択肢

`may retain ... cleanup according implementation contract`
を削除。

推奨:
- ordinary deleted tombstone 30d保持
- then cleanup
- cancelled recurring exceptionはparent recurring eventがcanonicalに存在する間、またはprojection horizonを過ぎるまで保持

## P3-2 weekly preflight idempotencyがまだ2案

09:
`own dispatch receipt or deterministic daily/weekly job key`

1方式へ固定。
推奨:
`scheduled_dispatch_receipts`とは別の
`private.worker_run_receipts(worker_kind,logical_slot_key)`。

## P3-3 dispatch_slot_keyのformatとsame-day schedule edit semanticsを固定

推奨:
`dispatch_slot_key = schedule_kind + ':' + local HH:MM + ':' + schedule_version`

schedule時刻変更後:
- 旧slot送信済みなら同日新slotを自動再送しない
- userが明示的に「今日から適用」を選んだ場合のみnew version slot送信可
等、UX/semanticsを1つに固定。

---

# 2. v3 P1再確認

| previous v3 item | v4 |
|---|---|
| nullable Google resource | PASS |
| Google deterministic create id | PASS |
| sync job states | PASS |
| Edge-only mutation intent | PASS, transport fix required P1-4 |
| Cron token | PASS |
| mutation contract | PASS except household setup |
| mutation receipt | PASS |
| Google credential household binding | PASS |
| scheduled recurrence time | PASS |
| busy attribution | PASS, composite FK fix required P1-8 |

---

# 3. 無料構成の判定

## Supabase
継続推奨。
現在設計のCron worker数でもFree Edge Function invocation枠に対して十分現実的な規模。

## Google Calendar
API課金よりquota/認証設計が主論点。
現在の家庭1calendar用途で問題なし。

## LINE
**現状のままでは「無料保証」はFAIL。**
200 counted push/month hard budgetを設計へ入れれば無料運用可能。

## R2
小規模暗号化dump用途なら無料枠内を狙える。
利用量は実測monitor。

---

# 4. 実装開始判定

## WP0
**GO**

## WP1
**HOLD**

理由:
- RPC実行schema/transport
- missing private queue/token schema
- household setup contract
- busy member composite FK

がWP1 schema/securityへ直接影響する。

v5で上記P1を反映し、もう1回SOL review。
**P0=0/P1=0ならWP1 GO**が妥当。

---

# 5. 最終評価

v4は設計品質としてかなり高い。
今回のREQUEST CHANGESは「また大改修」ではない。

残る本質は:

1. 無料LINE 200通を数学的に守る
2. LINE identity/private queue schemaを完成させる
3. Edge->DB RPCの実際の接続経路を成立させる
4. Household/OAuth setupをtransaction contract化する
5. Google query/stagingを完全固定する
6. busy-member FKを閉じる

ここまで直せば、v5ではP0/P1=0を十分狙える。
