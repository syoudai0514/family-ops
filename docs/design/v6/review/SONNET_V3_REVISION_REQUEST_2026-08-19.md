# Claude Code Sonnet向け — Family Ops v2 → v3 修正依頼

`family-ops-sonnet-plan-v2` は前版より大幅に改善しています。
ただし、実装開始前に下記を設計正本へ反映し、`family-ops-sonnet-plan-v3` を作成してください。

**AIのprivacy論点は今回blockerにしません。**
既存の `free_lightweight` 方針を維持してください。

## 絶対条件

### 1. Google watch channelをsync stateから分離

`private.google_watch_channels` を追加し、old/new watch overlapをDB上で同時表現できるようにする。

最低限:
- calendar_connection_id
- channel_id unique
- resource_id
- channel_token_hash
- expires_at
- status active/retiring/stopped/expired
- created_at/stopped_at

Webhookはactive/retiring channelだけ受理。

`google_sync_state` から単一watch前提のfieldsを削除または責務整理。

### 2. `private.google_sync_jobs` を正式schema化

architectureに存在するsync queueをDDL contractへ追加。

必要:
- queued/processing/done/failed/dead
- attempts
- next_attempt_at
- lease_owner/lease_until
- dedup/coalesce
- last_error

### 3. Google syncにperiodic correctness fallback

Google pushだけに依存しない。

推奨:
- active calendarを30分ごとincremental sync enqueue
- app openでstaleならenqueue
- manual refresh
- webhookとのduplicateはcoalesce

### 4. 全queueにlease/reclaim

対象:
- webhook_inbox
- notification_outbox
- google_sync_jobs
- pending_actions

worker crash後に永久`processing/sending/executing`にならないこと。

pending_actionはexternal side effectを含む場合に単純再実行しない。
action-specific idempotency/recovery contractを明記。

またworker起動方式/cadenceを固定し、
`Cron/pg_cron or scheduled Edge Function` のような未決定表現を残さない。

### 5. RLS policy matrixを追加

`fixtures/RLS_POLICY_MATRIX.md` または同等ファイルを作る。

public全tableについて:
- SELECT
- INSERT
- UPDATE
- DELETE
- direct client可否
- RPC only
- mutable columns
- household判定path

を明示。

immutable columnsはRLSだけに期待しない。
推奨はstateful UPDATEをRPC/Edge Functionへ集約。

child table:
- task_subtask_definitions
- task_subtask_instances
- handover_reads

のparent-join RLSも明記し、IDOR tests追加。

### 6. composite FKでhousehold整合性をDB保証

可能なresource/user referenceは:

`(household_id, foreign_id)`

のcomposite FKにする。

最低:
- recurrence rule -> task definition
- task instance -> task definition
- task instance -> recurrence rule
- request requester/recipient -> household_members
- planned/actual assignee -> household_members
- created_by/author/assigneeも適用可能範囲を洗い出す

### 7. one-time token tables追加

`private.household_invites`
`private.line_link_tokens`

raw tokenではなくhash保存。
TTL、single use、used_at、transactional claimを固定。

### 8. App Auth方式を固定

推奨:
**Supabase Auth Google Sign-In**

Calendar連携OAuthとは責務を分ける。
App login tokenをGoogle Calendar durable refresh tokenとして流用しない。

別方式にする場合もv3で1つに固定し、Sonnet実装時の判断に残さない。

### 9. Google sync query contractを固定

Google events.listのsyncToken制約を設計へ明記。

推奨:
- canonical change cache = fixed parameter + syncToken
- occurrence projection = Today/conflict用rolling window
- rolling timeMin/timeMaxをsyncToken requestへ混ぜない
- recurring master/instance/exception/cancelledをtest
- 410 full syncはstagingで全page成功後atomic reconcile

### 10. Google refresh token暗号化contract

`encrypted_refresh_token` の方式とkey sourceを固定。

推奨:
- Edge secret `TOKEN_ENCRYPTION_KEY`
- versioned AES-GCM envelope
- keyはDBへ保存しない

Supabase Vault採用でも可。ただしどちらかに固定。

## P2として同時修正

- public in-app notification/read model
- notification preferences（必要最小）
- raw_inputs/token/webhook retention cleanup job
- Backup CIからAGE private keyを削除しpublic keyだけにする
- private keyはpassword manager/offline
- weekday ISO Monday=1を明記
- Google all-day endはexclusiveと明記
- task/request static consistency CHECK強化
- recurrence future reconcileは原則todoのみ。in_progressの扱いを固定

## Tests追加

### Google
- old/new watch both accepted during overlap
- old stopped/expired rejected
- missed webhook -> periodic sync convergence
- recurring weekly instance
- recurring exception
- cancelled instance
- all-day recurring
- parameter drift guard
- 410 full sync page failure preserves old cache

### Queue
- worker dies after claim
- lease expiry -> reclaim
- duplicate reclaim -> one business side effect
- max attempts -> dead

### RLS
- foreign subtask definition
- foreign subtask instance
- foreign handover read
- profile enumeration
- cross-household assignee FK failure
- cross-household task_definition FK failure

### Tokens
- invite reused
- invite expired
- line link reused
- line link expired

## Output

v3 packageには最低:
- updated README
- updated architecture
- updated domain/data model
- updated security/RLS
- updated LINE
- updated Google Calendar
- updated API/functions
- updated work packages
- updated tests
- updated DDL contract
- updated ENV template
- updated fixtures
- `V3_CHANGELOG.md`

を含める。

完了後は実装を開始せず、v3 packageをSOL再レビューへ回すこと。
