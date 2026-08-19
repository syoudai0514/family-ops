# Family Ops v3 — GPT-5.6 Sol 独立再レビュー

日付: 2026-08-19  
対象: `family-ops-sonnet-plan-v3`  
判定: **REQUEST CHANGES**  
集計: **P0 0 / P1 10 / P2 8 / P3 3**

## 0. 前提

- AI privacy論点はユーザー判断でblockerにしない。
- Supabase継続方針は妥当。今回の指摘はSupabase採用自体を否定するものではない。
- v2で指摘した主要P1は、v3でかなり丁寧に反映されている。
- 今回の指摘は「v3で追加された仕組み同士を横断すると残る実装不能・不整合・未決定」を中心にしている。

## 1. 総評

v3はv2より明確に改善している。

前回指摘した以下は合格:
- google_watch_channels分離
- google_sync_jobs導入
- periodic sync fallback
- queue lease/reclaim
- RLS policy matrix
- one-time token tables
- App Auth固定
- canonical syncとoccurrence projection分離
- 410 staging
- AES-GCM token encryption
- age private keyのCI排除
- cleanup job
- future todo-only recurrence reconcile

しかし、**P0/P1=0にはまだ届いていない。**
特に以下は実装すると直接バグになるため、WP1 migration前にv4へ固定することを推奨する。

---

# P1

## P1-1 Google canonical cacheが有効なGoogle Event resourceを格納できない

### 対象
- `03_DOMAIN_AND_DATA_MODEL.md`
- `07_GOOGLE_CALENDAR.md`
- `15_DDL_CONTRACT.md`

### 問題

`public.calendar_events_cache.title text not null`
`public.calendar_event_occurrences.title text not null`

となっている。

Google Calendarでは:
- event summary/titleは必須ではない
- cancelled recurring exceptionは `id`, `recurringEventId`, `originalStartTime` しか保証されない
- 通常のdeleted eventは `id` しか保証されない

したがって正規のincremental sync結果がNOT NULL制約を破る。

### failure scenario

1. recurring eventの1 instanceをGoogle Calendar側で削除
2. incremental syncにcancelled exceptionが返る
3. summary/titleなし
4. canonical cache upsertでNOT NULL violation
5. transaction rollback
6. syncToken進まず
7. 次回syncでも同じ変更を受け続ける

### exact fix

canonical cacheはGoogle resourceの保証に合わせる。

- `title text null`
- cancelled/deleted時に保証されないfieldはnullable
- display時のみ `coalesce(title, '（無題）')`
- ordinary deleted eventはlocal active copyを削除/terminal tombstone化する契約を固定
- cancelled recurring exceptionはparent lifetime中minimal tombstoneを保持
- occurrence projectionはcancelled rowをactive occurrenceとして表示しない

### tests
- untitled normal event
- deleted event with id only
- cancelled recurring exception with id/recurringEventId/originalStartTime only
- sync transaction succeeds and token advances

---

## P1-2 Google Calendar createのidempotency方式がまだ未決定

### 対象
- `01_ARCHITECTURE.md` 9
- `06_LINE_INTEGRATION.md`
- `07_GOOGLE_CALENDAR.md` 12
- `fixtures/QUEUE_RECOVERY_CASES.json`

### 問題

現在:
`operation marker/extended propertyまたはreturned resource reconciliation`

と複数案が残っている。

Google Calendarはevent create時にclient-generated event IDを指定でき、Google自身がnetwork failure後のduplicate create防止用途として案内している。

### exact fix

Google createは1方式に固定する。

推奨:
1. Family Ops operation UUIDを生成
2. Google event IDをそのUUIDからGoogle許容base32hexへdeterministic変換
3. `extendedProperties.private.familyOpsOperationId`も付与
4. DBに `private.google_write_operations`
   - operation_id unique
   - calendar_connection_id
   - google_event_id
   - action
   - request_hash
   - status
   - result_etag
5. timeout時は**同じevent ID**でrecovery
6. 409 duplicate時はevents.get同IDで内容照合
7. operation_id同じ・payload違いはidempotency conflict

updateについても:
- target event ID固定
- timeout後fetch/reconcile
- etag/412 policyを固定

### tests
- backend success + client timeout
- retry same operation -> one event
- duplicate ID 409 -> existing event returned/reconciled
- same operation ID different payload -> deny

---

## P1-3 google_sync_jobsのretry state machineとactive uniquenessが矛盾

### 対象
- `03_DOMAIN_AND_DATA_MODEL.md`
- `09_API_AND_EDGE_FUNCTIONS.md`
- `15_DDL_CONTRACT.md`

### 問題

status:
`queued / processing / done / failed / dead`

partial unique:
`calendar_connection_id WHERE status IN ('queued','processing')`

しかし`failed`が:
- retryableなのか
- terminalなのか
が書かれていない。

`next_attempt_at`があるためretryableに見えるが、failedをretry対象にするとpartial unique外なので、新規queued jobとfailed retry jobが同じcalendarに並存できる。

さらにworker success + `rerun_requested` が:
`same logical job/reset or new queued`
と未決定。

### exact fix

1方式に固定。

推奨:
- transient failureは `processing -> queued`
- `next_attempt_at`設定
- lease clear
- attempts保持
- max attemptsで`dead`
- `failed` statusは削除
- success + rerun_requested:
  - 同じrowをatomicに `queued` へ戻す
  - rerun_requested=false
  - next_attempt_at=now()
  - lease clear
  - 直前run success時刻はsync stateへ記録
- partial uniqueはqueued/processingのまま

### tests
- transient error during processing
- new webhook arrives during backoff
- no second active job
- rerun_requested cannot be lost
- stale worker cannot terminal update

---

## P1-4 RPC / Edge Function mutation security boundaryが固定されていない

### 対象
- `04_SECURITY_RLS_PRIVACY.md`
- `09_API_AND_EDGE_FUNCTIONS.md`
- `15_DDL_CONTRACT.md`
- `fixtures/RLS_POLICY_MATRIX.md`

### 問題

方針:
`mutation = RPC / Edge Function`

だが、どのmutationをどちらにするか未定。

direct table mutationをrevokeしているため、
browserから直接Postgres functionを呼ぶ場合は権限設計が必要。

Supabase/Postgres functionはデフォルトEXECUTEが広いため、SECURITY DEFINERを使う場合は特に:
- search_path
- PUBLIC/anon/authenticated EXECUTE
- auth.uid()
- RLS bypass
を固定しないと危険。

### exact fix

v4で1方式に固定。

推奨MVP:
- browser mutation entrypoint = **Edge Function only**
- authenticated user JWTをEdgeで検証
- actor/householdをserver derive
- atomic DB transactionは専用DB RPCへ委譲
- transaction RPCはclient roleからEXECUTE不可
- server/secret roleだけEXECUTE
- SECURITY INVOKERを優先
- SECURITY DEFINERが必要なhelperのみ `SET search_path=''` + schema-qualified references

migration:
- `REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated`
- default privilegesもPUBLIC含めrevoke
- 許可関数だけ明示GRANT

### tests
- anon cannot execute mutation function
- authenticated cannot execute server-only tx function directly
- Edge JWT user can mutate own household
- cross-household fails
- malicious search_path cannot hijack function resolution

---

## P1-5 Cron -> Edge Function worker invocation authenticationが未固定

### 対象
- `01_ARCHITECTURE.md`
- `09_API_AND_EDGE_FUNCTIONS.md`
- `14_EXTERNAL_SETUP_STEPS.md`
- `ENV_TEMPLATE.md`

### 問題

worker起動をSupabase Cron + Edge Functionsに固定した一方、
Cronからworker endpointを**何で認証するか**がない。

publishable keyはworker privilegeの認証にはならない。

### exact fix

専用worker token方式を固定。

推奨:
- 256-bit `CRON_WORKER_TOKEN`
- Supabase Vaultにも同値を保存
- Edge Function secretにも保存
- pg_cron/pg_netが `X-Family-Ops-Worker-Token` を送る
- worker endpointはJWT gatewayに依存せず、tokenをconstant-time verify
- token missing/wrong -> 401
- browser用functionsとworker-only functionsを分離
- token rotation runbook

ENV/Setup/Migrationへ追加。

### tests
- no token -> reject
- wrong token -> reject
- valid Cron token -> worker claim
- token never logged

---

## P1-6 Core PWA mutation APIが不足しており、Sonnetに設計判断が残る

### 対象
- `09_API_AND_EDGE_FUNCTIONS.md`
- `10_WORK_PACKAGES.md`
- `00_PRODUCT_AND_SCOPE.md`

### 問題

09にはrequest/task complete/recurrence等はあるが、MVPで必要な以下のcontractがない。

- manual task create/edit/cancel
- once reassignment
- subtask complete/uncomplete
- task definition create/edit/deactivate
- shopping add/assign/order/purchase/arrive/cancel
- handover create
- handover mark-read
- notification mark-read
- notification preference update

WP2/WP3では実装対象なのにAPI正本がない。

### exact fix

`MUTATION_CONTRACT_MATRIX.md` を追加。

各mutation:
- function name
- user input
- actor/household derivation
- precondition
- DB transition
- idempotency
- event/outbox side effect
- return value
- replay behavior
を固定する。

---

## P1-7 PWA mutation全般のidempotencyが不足

### 対象
- `00_PRODUCT_AND_SCOPE.md`
- `01_ARCHITECTURE.md`
- `09_API_AND_EDGE_FUNCTIONS.md`

### 問題

「LINE/PWA/Googleどこから変更しても冪等」とあるが、
idempotency contractは主にLINE/Google external side effectだけ。

PWAで:
- request送信
- manual task作成
- handover登録
- shopping追加
等をdouble tap / response timeout retryするとduplicate rowを作れる。

### exact fix

client-originated create/transitionに`operation_id UUID`を必須化。

推奨:
`private.mutation_receipts`
- actor_id
- operation_id
- action_type
- request_hash
- result_type
- result_id
- created_at
- unique(actor_id,operation_id)

transaction:
1. receipt claim
2. same operation + same hash -> existing result return
3. same operation + different hash -> idempotency conflict
4. business mutation
5. event/outbox
6. result receipt commit

### tests
- double tap
- lost HTTP response then retry
- concurrent same operation
- same operation different payload

---

## P1-8 Google credentialがhouseholdへDB bindingされていない

### 対象
- `03_DOMAIN_AND_DATA_MODEL.md`
- `15_DDL_CONTRACT.md`

### 問題

`private.google_connections`:
- owner_user_id
- household_idなし

`public.calendar_connections`:
- household_id
- google_connection_id -> private.google_connections(id)

このためservice-side bugで:
Household A calendar -> Household B userのGoogle credential
をDB FKが拒否できない。

v3の「same-household relationをDBで可能な限り保証」と矛盾。

### exact fix

`private.google_connections`へ:
- household_id uuid not null
- unique(household_id,id)
- composite FK `(household_id,owner_user_id)` -> household_members

`public.calendar_connections`:
- `(household_id,google_connection_id)` -> private.google_connections(household_id,id)

### test
- A calendar + B credential -> FK failure

---

## P1-9 定例タスクに時刻がなく送迎衝突判定を実装できない

### 対象
- `03_DOMAIN_AND_DATA_MODEL.md`
- `07_GOOGLE_CALENDAR.md`
- `fixtures/INITIAL_TASK_SEED.yaml`

### 問題

conflict detection:
`pickup/dropoffの予定時刻±60min`

しかしrecurrence_rulesに時刻fieldがない。

task_instanceには`due_at`があるが、materializerがどこから時刻を得るか不明。

### exact fix

`recurrence_rules`へ:
- `scheduled_local_time time null`
- `conflict_window_minutes int null default 60` またはglobal config

materializer:
- `scheduled_date + scheduled_local_time + household timezone`
- -> `due_at timestamptz`

送迎ではscheduled_local_timeを設定可能にする。
実際の時刻はseedに勝手に固定せず、初期セットアップ/PWA設定で入力できるようにする。

### tests
- JST local date/time -> UTC due_at
- DST-capable timezone generic test
- rule change keeps future todo due_at aligned
- pickup conflict ±window

---

## P1-10 Shared calendar eventに「誰の予定か」がなく、担当衝突判定が成立しない

### 対象
- `03_DOMAIN_AND_DATA_MODEL.md`
- `07_GOOGLE_CALENDAR.md`
- `02_UX_AND_SCREENS.md`

### 問題

Calendar cacheにある人物情報は主に:
`creator_mapped_user_id`

しかしcreatorは「誰が予定を作ったか」であり、
「誰がその時間busyか」ではない。

例:
- パパがママの病院予定を登録
- creator=パパ
- pickup planned=パパ
- creatorをbusy personと誤解するとfalse conflict

逆もある。

さらにGoogle eventの`transparency`を保存していないため、
「予定ありだがFree/transparent」のeventまでbusy扱いする可能性がある。

### exact fix

busy attributionを別概念としてモデル化。

推奨:
`public.calendar_occurrence_busy_members`
- calendar_connection_id
- occurrence_key
- household_id
- user_id
- source (`family_ops_metadata`,`manual`)
- PK(calendar_connection_id,occurrence_key,user_id)
- composite FK to household_members

event create from PWA/LINE:
- `誰の予定？ パパ / ママ / 家族`
- Family Ops metadataをGoogle extendedPropertiesへ保存
- syncでbusy member mapping復元

Google直接作成でmetadataなし:
- `busy owner = unknown`
- creatorをbusy ownerへ自動変換しない
- false positiveを避ける
- UIで後から分類可

さらにcache/projectionへ:
- `transparency`
を保存。
`transparent`はconflict対象外。

### tests
- papa creates mama appointment
- family event both busy
- unknown direct Google event
- transparent event
- mapped mama event does not block papa pickup

---

# P2

## P2-1 Google OAuth Testing statusの7日refresh token expiryをsetup gateへ明記

Google OAuth external appがTesting publishing statusの場合、
基本profile scope以外を使うrefresh tokenは7日でexpireする。

現在「production publishing/consent status」は書いてあるが、
この理由とgateを明示した方がよい。

修正:
- family use開始前にCalendar OAuth project `In production`
- Testingでは7-day reauthがexpectedであることをrunbookへ
- `invalid_grant` -> reauth_required test

---

## P2-2 child contributor/read receiptのsame-household DB guaranteeが弱い

- `task_subtask_instances.completed_by`
- `handover_reads.user_id`

はchildにhousehold_idがなく、composite FK不可。

RPC authorizationはあるがDB consistencyが完全ではない。

選択:
- childへhousehold_idを持たせcomposite FK
- またはconstraint triggerを固定

最低test:
service-side insertでforeign userを入れてもDB reject。

---

## P2-3 calendar creator_mapped_user_idもsame-household FKを付ける

`calendar_events_cache.creator_mapped_user_id`
`calendar_event_occurrences.creator_mapped_user_id`

nullable composite FK:
`(household_id,creator_mapped_user_id) -> household_members`

---

## P2-4 Notification dedup keyのscopeをrecipient/channel込みに固定

現在:
`dedup_key text unique`

key生成規約がないため、同一business eventを夫婦2人へ通知すると、
同じdedup_key生成実装では2人目をunique conflictで落とす危険。

推奨:
- outbox unique `(recipient_user_id,channel,dedup_key)`
- in-app unique `(recipient_user_id,dedup_key)`
またはdedup key canonical formatにrecipient/channel必須。

test:
same request event -> papa/mama各1 notification。

---

## P2-5 request `cancelled` lifecycleを固定または削除

scopeは主に:
pending -> accepted/completed
pending -> declined

一方DBにはcancelledあり、CHECKは`completed_at null`しかない。

決める:
- requester can cancel pending only
- accepted後cancel不可
など。

不要ならMVP enumから削除。

---

## P2-6 Shopping state machineを固定

enumだけでtransition contractがない。

最低:
- wanted -> assigned optional
- wanted/assigned -> purchased for store
- wanted/assigned -> ordered -> arrived for online
- active -> cancelled
- terminalからrewind禁止
- timestamp consistency

API matrixへ含める。

---

## P2-7 「all-dayをbusy扱い可能」という設定がmodelに存在しない

07には:
`all-day予定は原則warning候補外、設定でbusy判定可能`

しかしsettings table/fieldなし。

MVPならどちらか:
- **設定機能を削除し、all-dayは常にconflict対象外**
- household_settingsへboolean追加

選択を固定。

---

## P2-8 INITIAL_TASK_SEEDのspecial_preparationsがschemaへmappingされていない

YAML:
`special_preparations`
- monday
- tuesday
- thursday

しかし対応table/seed変換contractなし。

WP1 gateは`db reset + seed`を要求するため、fixtureを正規化する。

推奨:
- prep_monday / prep_tuesday / prep_thursdayをtask_definition(subtasks)化
- recurrence_ruleへ変換
- pool-day conditional preparationはMVPではmanual/calendar-assistへ明記

---

# P3

## P3-1 Normative DDLに実装時選択肢が残る

`15_DDL_CONTRACT.md`:
- SET NULL if safe / otherwise RESTRICT

`08_RECURRING...`:
- exclusion constraint possibleなら / otherwise lock

v4では固定:
- historical definition/rule FK -> RESTRICT + deactivate only
- recurrence overlap -> DB exclusion constraintを採用、またはtransaction lock方式へ1つに固定

## P3-2 Google invalid watch response codeを固定

`2xx/ignore or 4xx`

job enqueueしない点は正しい。
MVPではprovider retry stormを避けるため、unknown/stopped/expiredは2xx ignore + structured warning等、1方式へ固定。

## P3-3 retention文言の選択肢を削除

`expired unused line_link_tokens: delete after 7d tombstone window or hard delete`

どちらかに固定。
監査不要ならMVPはhard deleteで十分。

---

# 2. 前回P1の再確認

前回の9件は概ねFIXEDと評価する。

| v2 review item | v3 |
|---|---|
| watch overlap schema | PASS |
| sync job table | PASS（state machine追加修正要） |
| periodic sync fallback | PASS |
| queue lease/reclaim | PASS |
| RLS matrix / immutable | PASS（function execution model補強要） |
| composite FK | PASS（Google credential等補強要） |
| invite/link token | PASS |
| App Auth fixed | PASS |
| canonical vs occurrence split | PASS |

---

# 3. 実装開始判定

## WP0
**GO**

repo/bootstrap/local Supabase/CIまでは進めてよい。

## WP1
**HOLD**

理由:
今回のP1のうち複数がWP1 schema/securityへ直接影響する。

特に:
- calendar cache nullability
- google_connections household binding
- recurrence scheduled time
- busy-member mapping
- RPC/function grant model
- mutation idempotency receipt
- seed normalization

をmigration前に固定する方が手戻りが少ない。

---

# 4. Human setupで追加明記

1. Calendar OAuth projectのPublishing Status
2. TestingではCalendar refresh tokenが7日で失効すること
3. production family use前にIn productionへ
4. Cron worker tokenをSupabase Vault + Edge secretsへ同時設定
5. 送迎の実時刻は初回設定で入力
6. Google eventのbusy person metadata方針を夫婦運用へ合わせる

---

# 5. Overengineering削減候補

現在設計は堅牢だが、夫婦2人用MVPとしてはGoogle watch周辺が最も重い。

## Option A — 最短MVP
Google watch/pushをWP7後半へ延期。

MVP:
- app open stale sync
- manual refresh
- 10〜15分periodic incremental sync

これなら:
- google_watch_channels
- webhook channel token
- renewal overlap
- channel stop/recovery
の実装とテストを初回releaseから外せる。

欠点:
Google直接変更のLINE/PWA反映が最大10〜15分遅れる。

## Option B — 現行堅牢版
v3方針どおりpush + periodicを維持。

家庭運用でも即時性を優先するならこちらでよい。

**削らない方がよいもの**
- RLS
- same-household FK
- request accept semantics
- mutation idempotency
- queue lease/reclaim
- off-site backup

これらは機能数ではなく「壊れたときのデータ不整合」を防ぐ土台なので維持推奨。

---

# 6. 最終判定

**REQUEST CHANGES**

ただしv3はv1/v2よりかなり完成度が高い。
今回のv4修正は再設計ではなく、主に:

1. Google resourceの実データ形にschemaを合わせる
2. mutation/security/idempotency entrypointを1方式へ固定
3. 送迎 conflict detectionに必要な「時刻」「誰がbusyか」をdata modelへ追加
4. 残っている実装時選択肢を消す

という仕上げ。

v4で上記を正本化すれば、次回P0/P1=0を十分狙える。
