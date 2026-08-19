# Family Ops v2 — GPT-5.6 Sol 再レビュー

日付: 2026-08-19  
対象: `family-ops-sonnet-plan-v2`  
判定: **REQUEST CHANGES**  
集計: **P0 0 / P1 9 / P2 8 / P3 2**

## 0. 前提

ユーザー判断により、Gemini無料枠へ送る内容は軽い家庭ToDo等に限定し、AI部分のプライバシー論点は今回のblockerにしない。
`free_lightweight`、manual fallback、raw fallback禁止というv2の方針で進めてよい。

## 1. 総評

v1から大幅に改善している。前回の主要指摘はほぼ設計に反映されている。

特に以下は合格:
- `household_members` をmembershipの唯一の正本にした
- client supplied `actor_id` / `household_id` を認可根拠にしない
- blanket same-household UPDATEを禁止した
- requestはsend時にtaskを作らずaccept時にatomic create/link
- recurring occurrenceをrule versionから独立させた
- subtasksの複数contributorを保持する
- LINE durable inbox/outboxを導入した
- Google Calendar sync owner / lease / syncToken advancementを明文化した
- handover read receiptを追加した
- offline writeをMVPから外した
- AI golden fixtureを32件まで増やした
- backup + restore drillをrelease gateにした

したがって「作り直し」ではない。
ただし、複数ドキュメントを横断すると、Sonnetが実装時に勝手な設計判断をしないと完成できない箇所がまだ残る。

**WP0は開始可。WP1 migration着手前に下記P1をv3へ反映することを推奨。**

---

# P1

## P1-1 Google watch renewalを現在のDB schemaでは表現できない

### 問題

`07_GOOGLE_CALENDAR.md` はrenewal時に、

1. new watch establish
2. new state active
3. overlap中はold/new両方受信
4. dedupe
5. old channel stop

と定義している。

一方 `private.google_sync_state` は以下を1組しか保持できない。

- `watch_channel_id`
- `watch_resource_id`
- `watch_channel_token_hash`
- `watch_expires_at`

これではold/newの2channelが同時にactiveな期間を表現できない。

Google Calendar公式仕様でも、renew時は新しいunique channel IDを作り、旧channelとのoverlap periodが発生し得る。

### 必須修正

watchをsync stateから分離する。

推奨:

```text
private.google_watch_channels
- id uuid pk
- calendar_connection_id uuid not null
- channel_id text not null unique
- resource_id text not null
- channel_token_hash text not null
- expires_at timestamptz not null
- status text not null check in ('active','retiring','stopped','expired')
- created_at timestamptz not null
- stopped_at timestamptz null
```

Webhookは `channel_id + resource_id + token hash` が `active/retiring` rowに一致した場合のみ受理。

renew:
- new row insert(active)
- old row retiring
- overlap中は両方valid
- old stop成功後stopped
- stop失敗でもexpirationまではvalid

### Test追加

- old/new 2channelがDBに同時存在
- old notification valid
- new notification valid
- unknown channel deny
- old stop後deny
- expiration後deny

---

## P1-2 `calendar_sync_jobs` がarchitectureにあるのにdata modelに存在しない

### 問題

`01_ARCHITECTURE.md`:

`GWH -> calendar_sync_jobs -> serialized calendar sync`

`07_GOOGLE_CALENDAR.md`:

`webhook -> enqueue sync job`

しかし `03_DOMAIN_AND_DATA_MODEL.md` に `calendar_sync_jobs` tableがない。

これではSonnetがqueue schema / dedupe / retry / dead-letterを新規設計する必要がある。

### 必須修正

`private.google_sync_jobs` をDDL contractへ追加する。

最低限:

```text
- id uuid pk
- calendar_connection_id uuid not null
- reason text not null
- dedup_key text not null
- status queued/processing/done/failed/dead
- attempts int
- next_attempt_at timestamptz
- lease_owner text null
- lease_until timestamptz null
- last_error text null
- created_at/updated_at
```

同時webhookをcoalesceできるunique/partial unique戦略も固定する。

---

## P1-3 Google push欠落時のperiodic reconciliationがない

### 問題

現在はGoogle webhookを主トリガーにしている。

Google公式はCalendar push notificationが100% reliableではなく、通常運用でも一部messageがdropし得るため、欠落しても同期できるようにする必要があると明記している。

Family OpsではGoogle Calendarが予定の正本なので、pushを1件落としただけでPWA cacheが長時間古いままになる設計は避けるべき。

### 必須修正

pushは「低遅延signal」、定期syncを「correctness fallback」にする。

推奨:
- active calendarを30分ごとにincremental sync enqueue
- app起動時、`last_incremental_sync_at` が15〜30分以上古ければsync enqueue
- manual refreshも可能
- 同じcalendarは既存job/leaseでcoalesce

夫婦2人・1 calendarなら無料枠上の呼び出し量は十分小さい。

### Test追加

- webhookを一切受けない変更でもperiodic syncで収束
- duplicate periodic + webhookでも1 logical sync
- project pause/resume後に収束

---

## P1-4 inbox/outbox/pending actionがworker crashで永久停止し得る

### 問題

現在:

- webhook inbox: `received -> processing`
- notification outbox: `pending -> sending`
- pending action: `pending -> executing`

となっている。

しかしworkerがclaim直後に落ちると、`processing/sending/executing` rowをreclaimする規則がない。

Google syncだけは `lease_until` があるが、LINE/notification/pending actionにはない。

### 必須修正

queue型tableにlease/reclaimを導入。

推奨:
- `lease_owner`
- `lease_until`
- `last_started_at`
- claimは `FOR UPDATE SKIP LOCKED` またはatomic UPDATE
- lease expired rowはretry可能
- max attempts後dead

`pending_actions` は外部side effectを含む可能性があるため、単純にexecutingをpendingへ戻さない。
action typeごとにidempotency keyを使い、recovery時に「実行済みか」を確認できる契約を追加する。

### 必須で固定するworker起動

`Cron/pg_cron or scheduled Edge Function` のまま選択肢にしない。

少なくとも以下をv3で固定:
- process-line-inbox cadence
- send-notifications cadence
- sync-google-calendar cadence/fallback
- renew-google-watch cadence
- materialize-recurring cadence
- cleanup-expired cadence

---

## P1-5 RLS方針は改善したが、列のimmutable保証とchild table policyが未確定

### 問題A: immutable列

`15_DDL_CONTRACT.md` は、

- household_id
- created_by
- requester_id
- recipient_id
- logical_occurrence_key
- origin

等を「normal clients cannot update」としている。

しかしRLSは主にrow単位の制御。
`UPDATE` をtableにgrantしたままでは、どの列を変更できるかを別レイヤーで固定する必要がある。

### 必須修正

次のどちらかをtableごとに固定:

A. client UPDATEを原則禁止しRPC/Edge Functionに集約  
または  
B. column-level GRANTで更新可能列だけ許可 + RLS

Family OpsではAを推奨。
read中心direct access、状態遷移はRPC/Functionへ寄せた方が安全でテストしやすい。

### 問題B: household_idを持たないpublic child table

例:
- `task_subtask_definitions`
- `task_subtask_instances`
- `handover_reads`

これらのRLSはparent joinが必要。
現在のnegative matrixではchild tableのIDORを直接検証していない。

### 必須修正

`RLS_POLICY_MATRIX.md` を新設し、public全tableについて以下を列挙:

- SELECT誰が可
- INSERT誰が可
- UPDATE誰が可
- DELETE誰が可
- direct / RPC only
- allowed mutable columns
- household判定path

最低追加test:
- foreign task_subtask_definition SELECT/UPDATE
- foreign task_subtask_instance completion
- foreign handover_read INSERT/DELETE
- profile enumeration deny
- partner profile select only same household
- household update path

---

## P1-6 household内整合性をDB FKで十分に保証していない

### 問題

Edge Functionでrecipient/assigneeの同household確認をしているのは良い。

ただしDDL上は、多くのUUID FKが「同じhouseholdのresource/memberであること」まで保証していない。

例:
- recurrence ruleのtask_definitionが別household
- task instanceのtask_definition / recurrence_ruleが別household
- planned_assigneeが別household user
- request recipient/requesterが別household user

service-side bugが1回起きるだけでcross-household inconsistent rowを作れる。

### 必須修正

可能なものはcomposite FKにする。

例:

```text
household_members PK(household_id,user_id)

task_definitions UNIQUE(household_id,id)
recurrence_rules UNIQUE(household_id,id)
task_instances UNIQUE(household_id,id)

recurrence_rules(household_id,task_definition_id)
  -> task_definitions(household_id,id)

task_instances(household_id,task_definition_id)
  -> task_definitions(household_id,id)

task_instances(household_id,recurrence_rule_id)
  -> recurrence_rules(household_id,id)

requests(household_id,requester_id)
  -> household_members(household_id,user_id)

requests(household_id,recipient_id)
  -> household_members(household_id,user_id)
```

同様にplanned/actual/created_by/author/assignee等も適用可能範囲を洗い出す。

DBで表現しづらいchild completed_by等はRPC/trigger testで保証。

---

## P1-7 household invite / LINE linkのone-time token schemaがない

### 問題

API/LINE設計では:

- `invite-or-join-household` one-time invite token
- LINE linking one-time link token

を使う。

しかしprivate schemaにtoken tableがない。

Sonnetが勝手に保存方式、TTL、hash、single-use semanticsを決めることになる。

### 必須修正

追加:

```text
private.household_invites
- token_hash unique
- household_id
- created_by
- expires_at
- used_at
- used_by
- created_at
```

```text
private.line_link_tokens
- token_hash unique
- user_id
- expires_at
- used_at
- created_at
```

raw tokenはDB保存しない。
使用はtransactional compare-and-set。
expired/reused token test必須。

---

## P1-8 アプリのSupabase Auth方式が未確定

### 問題

WP1 = Auth/RLS、WP2 = loginとあるが、ログイン方式がどこにも固定されていない。

一方Sonnet promptは「仕様上の選択肢は勝手に増やさない」「人間へ聞くのは外部credentialだけ」としているため矛盾する。

またSupabase built-in SMTPは現在、custom SMTP未設定ではproject team以外への送信を拒否する制約があり、best-effort / low rate limitでproduction向けではない。
よって「なんとなくMagic Link/Password Reset」を採用すると妻アカウントで詰まる可能性がある。

### 推奨決定

**MVP app login = Supabase AuthのGoogle Sign-In** を推奨。

理由:
- 夫婦ともGoogle Calendarを使う前提
- パスワード管理不要
- custom SMTP追加不要
- 無料構成を維持しやすい

ただし、
**App AuthのGoogle OAuthと、Calendar sync owner用OAuthは責務を分離する。**
Calendar側はoffline access / Calendar scopes / durable refresh tokenが必要なので、ログインsession tokenに依存させない。

別方式にするならv3で明示すること。

---

## P1-9 Google incremental syncのquery contractとrecurring event展開が未確定

### 問題

Google `events.list` はsyncToken利用時に以下を同時指定できない:

- timeMin
- timeMax
- updatedMin
- orderBy
- q
- その他一部

また、初回syncとincremental syncで許可されている他parameterを同じに保つ必要がある。

現在のplanは:
- incremental sync
- Today表示
- conflict detection
- recurring event
を要求しているが、
`singleEvents`, `showDeleted`, time range等のquery contractが固定されていない。

Sonnetが「rolling 30日 + syncToken」のようなGoogle API上不正な設計を作る余地がある。

### 必須修正

Google cacheを2責務に分けることを推奨。

#### A. canonical change cache
Google resourceの変更追跡用。
- fixed query parameter contract
- syncToken
- recurring master / exceptionを正しく保持
- 410時はstaging full sync完了後にatomic reconcile

#### B. occurrence projection
Today / conflict detection用。
- rolling window（例: -7日〜+60日）
- recurring instanceをexpand
- canonical sync後 / periodic jobでrefresh
- syncTokenとは混ぜない

最低限、どの方式を採るかをv3で固定する。

### Test追加

- recurring weekly eventがTodayにinstanceとして出る
- recurring exception/moved instance
- cancelled instance
- all-day recurring event
- initial queryとincremental query parameter driftを検知
- 410 full sync途中失敗でも既存cacheを空にしない

---

# P2

## P2-1 in-app notificationの永続modelがない

MVP channelは`LINE + in_app`だが、private notification_outboxはPWAから読めない。

追加推奨:
- `public.user_notifications`
- recipient_user_id
- household_id
- type
- title/body/shared payload
- read_at
- created_at
- dedup_key

通知設定も必要なら:
- `public.notification_preferences`

---

## P2-2 refresh token暗号化方式が未定義

`encrypted_refresh_token` とだけあり、暗号鍵の所在/rotationがない。

推奨:
- Edge secret `TOKEN_ENCRYPTION_KEY`
- versioned AES-GCM envelope
- DBにkeyを置かない
- key rotation/re-encrypt runbook

Supabase Vaultを採用するならそれを正本として明示してもよい。

---

## P2-3 backup CIにage private keyを置かない

`ENV_TEMPLATE.md` のBackup CI secretsに:

- `BACKUP_AGE_PUBLIC_KEY`
- `BACKUP_AGE_PRIVATE_KEY`

の両方がある。

backup作成CIは**public keyだけ**で暗号化できる。
private keyまでGitHub Secretへ置くと、GitHub Actions側侵害時にbackupの暗号化分離が弱くなる。

修正:
- CI: public keyのみ
- private key: ownerのpassword manager / offline保管
- restore jobは手動・限定環境でprivate keyを使う

---

## P2-4 raw_inputs TTL cleanupがない

`expires_at` はあるがpurge jobがない。

`cleanup-expired-private-data` を定期実行:
- expired raw_inputs delete
- expired line link/invite tokens delete or tombstone
- old processed webhook payload retention
- dead queue retention policy

---

## P2-5 task/requestの状態とtimestamp整合CHECKを強化

例:
- whole completed -> actual_completed_by_id not null
- subtasks mode -> actual_completed_by_id null
- completed -> completed_at not null
- request accepted -> accepted_at not null
- declined -> declined_at not null

全てをCHECKに入れる必要はないが、静的に表現できる不変条件はDBへ寄せる。

---

## P2-6 weekday番号を明記

`weekday 1..7` はあるが、
**ISO: Monday=1 ... Sunday=7**
をDDL / seed / parser contractに明記する。

AI fixtureのweekday数値とも同じ規約を使う。

---

## P2-7 Google all-day endのexclusive semanticsを明記

Google Calendarのall-day `end.date` はexclusive endとして扱う。

`all_day_start/all_day_end` namingだけでは実装者がinclusiveに解釈し得る。

fieldを:
- `all_day_start`
- `all_day_end_exclusive`

にするかコメントで固定。
timezoneもevent/calendar timezoneの扱いをtestする。

---

## P2-8 recurrence reconciliationでin_progressを自動書換するか再検討

現在:
future `todo/in_progress` instanceを新ruleへreconcile。

作業開始済みの`in_progress`まで担当を書換すると履歴の意味が崩れる可能性がある。

推奨:
- auto reconcile = future `todo` only
- `in_progress` は現在担当を保持し、必要なら明示操作

少なくとも仕様を固定する。

---

# P3

## P3-1 worker cadenceをENV/config化

queue cadence、periodic Google sync stale threshold、retry max、retention day等をmagic numberにしない。

## P3-2 source docsのverified dateを残す

Google/Supabase/LINEの外部仕様は変化し得るため、SOURCE_SNAPSHOTに確認日を入れる。

---

# 2. 前回指摘の再確認結果

| 前回項目 | v2 |
|---|---|
| membership canonical | PASS |
| blanket UPDATE RLS排除 | PASS（ただしP1-5補強要） |
| recurrence stable occurrence | PASS |
| subtask contributors | PASS |
| request accept時task create | PASS |
| LINE durable inbox/outbox | PASS（ただしlease補強要） |
| pending atomic claim | PASS（ただしcrash recovery補強要） |
| Google channel token | PASS |
| serialized sync / token advancement | PASS |
| sync owner | PASS |
| backup MVP | PASS（age key配置のみ修正） |
| DDL contract | PASSだがcomposite FK/RLS column契約補強要 |
| handover reads | PASS |
| offline write削除 | PASS |
| AI fixtures 30+ | PASS: 32件 |
| Today hierarchy | PASS |
| pause recovery | PASS |

---

# 3. 実装開始判定

## WP0

**GO**

repo/bootstrap/CI/local Supabaseまで開始してよい。

## WP1

**HOLD**

理由:
WP1はschema/RLS/Authを固定するwork packageであり、今回のP1-5〜P1-8がそのままWP1のmigration contractに影響する。

特に:
- Auth方式
- RLS/column mutation contract
- household composite FK
- invite token schema

をmigration前に決める方が、後からmigrationを壊すより圧倒的に安い。

## WP2以降

WP1 gate PASS後。

---

# 4. 最終評価

v2は「危ない計画」ではなく、**かなり良い計画に到達している**。

v1の主要blockerは実質解消した。
今回のREQUEST CHANGESは方向転換ではなく、
**実装時にSonnetへ残っている暗黙の設計判断を潰すためのv3仕上げ**。

特に優先順位は:

1. Google watch channel table
2. Google sync jobs + periodic fallback
3. queue lease/recovery
4. exact RLS/column contract
5. composite FK
6. invite/link token tables
7. Auth方式固定
8. Google recurring/sync query contract
9. refresh-token encryption contract

ここまで固定すれば、次回はP0/P1=0を十分狙える。
