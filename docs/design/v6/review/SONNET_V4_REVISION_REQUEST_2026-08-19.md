# Claude Code Sonnet向け — Family Ops v3 → v4 修正依頼

対象: `family-ops-sonnet-plan-v3`

v3は前回P1を大幅に解消しています。
ただし独立再レビューで新たな実装ブロッカーが見つかったため、**実装せず設計v4のみ作成**してください。

判定:
REQUEST CHANGES  
P0 0 / P1 10 / P2 8 / P3 3

AI privacy論点はblockerにしません。

## 最優先修正

### 1. Google cancelled/deleted/untitled event対応

`calendar_events_cache.title`をnullableへ。
Googleが保証しないfieldsはcancelled/deleted時nullable。

contract:
- ordinary deleted event: local active copy remove/terminal handling
- cancelled recurring exception: minimal tombstone保持
- display fallback titleはUI/query側
- occurrence projectionでcancelledをactive表示しない

tests追加。

### 2. Google create idempotency方式を1つに固定

client-generated Google event IDを採用。

- local operation UUID
- Google許容base32hex event IDへdeterministic変換
- extendedProperties.privateにFamily Ops operation ID
- `private.google_write_operations`追加
- timeout recovery
- 409 duplicate recovery
- same operation different payload conflict

update timeout/etag/412 policyも固定。

### 3. google_sync_jobs state machine修正

`failed` ambiguityを削除。

推奨:
- queued
- processing
- done
- dead

transient:
processing -> queued + next_attempt_at

success + rerun_requested:
same rowをatomic queuedへ戻す方式へ固定。

active uniqueness / lease / attempts / max attempts tests更新。

### 4. Mutation entrypointを固定

`RPC / Edge Function`の選択を残さない。

推奨:
- browser mutation entry = Edge Function
- user JWT verify
- actor/household server derive
- atomic transactionはserver-only DB RPC
- authenticated/anonはtransaction RPC EXECUTE不可
- function grantsをPUBLIC含めdefault revoke
- SECURITY DEFINERは必要最小限、必ずsearch_path空 + schema-qualified

`MUTATION_CONTRACT_MATRIX.md`を新設。

### 5. Cron worker authenticationを固定

`CRON_WORKER_TOKEN` 256-bit。

- Supabase Vault
- Edge Function secret
- pg_cron/pg_net custom header
- constant-time verify
- wrong/missing token reject
- log禁止
- rotation

ENV/Setup/Architecture/Testへ反映。

### 6. Core PWA mutation contractを全件定義

最低:
- manual task create/edit/cancel
- task complete
- subtask complete/uncomplete
- once reassignment
- task definition create/edit/deactivate
- send/accept/decline/cancel request
- shopping add/assign/order/purchase/arrive/cancel
- handover create/mark-read
- notification mark-read
- notification preferences
- recurrence change

各:
- name
- input
- authorization
- preconditions
- DB mutation
- idempotency
- event/outbox
- return/replay
を固定。

### 7. PWA mutation idempotency追加

`private.mutation_receipts`

- actor_id
- operation_id
- action_type
- request_hash
- result_type/result_id
- created_at
- unique(actor_id,operation_id)

全client create/state transitionはoperation_idを持つ。
同operation同payload -> existing result。
同operation別payload -> conflict。

### 8. Google credentialをhouseholdへbinding

`private.google_connections`:
- household_id
- unique(household_id,id)
- composite FK household/owner -> household_members

`calendar_connections`:
- composite FK household/google_connection -> private google_connections

cross-household credential test。

### 9. Recurrenceに時刻を追加

`recurrence_rules`:
- scheduled_local_time time null
- conflict_window_minutes optional/default 60

materializer:
scheduled_date + local_time + household timezone -> due_at。

送迎時刻はuser setupで入力。
勝手にseedへ固定しない。

### 10. Calendar busy-person attribution

creatorとbusy personを分離。

追加推奨:
`public.calendar_occurrence_busy_members`
- household_id
- calendar_connection_id
- occurrence_key
- user_id
- source
- composite FK household/user
- FK occurrence

PWA/LINE create:
誰の予定かを選択しGoogle extendedPropertiesへFamily Ops metadata保存。

direct Google eventでmetadataなし:
- unknown
- creatorをbusy userと推測しない

cache/projectionに`transparency`も保存。
transparentはconflict対象外。

## P2も同時反映

1. Google OAuth Testing statusはCalendar refresh tokenが7日expireすることをsetup/runbookへ明記
2. family use前にCalendar OAuth app `In production` gate
3. task_subtask_instances.completed_by same-household DB constraint/trigger
4. handover_reads.user_id same-household DB constraint/trigger
5. calendar creator_mapped_user_id composite FK
6. notification dedup scopeをrecipient/channel込み
7. request cancelled lifecycle固定または削除
8. shopping state machine固定
9. all-day busy settingを実装するか機能文言削除
10. `INITIAL_TASK_SEED.yaml` special_preparationsをtask definitions/recurrenceへ正規化
11. source_definition_id FKも確認

## P3 cleanup

### ON DELETE
選択肢禁止。
history table参照は原則RESTRICT + deactivate。

### recurrence overlap
方式を1つに固定。
可能ならPostgres exclusion constraint + btree_gistを採用しmigration test。

### watch invalid request
2xx ignore + structured warning等1方式へ固定。

### token cleanup
`tombstone or hard delete`を1つに固定。

## Tests追加

### Google schema
- untitled normal event
- id-only deleted event
- minimal cancelled recurring exception
- syncToken advances

### Google write
- create backend success/response loss
- same operation retry -> one event
- 409 duplicate recovery
- operation ID payload mismatch

### sync job
- transient -> queued
- webhook during backoff
- rerun_requested during processing
- one active job invariant

### security
- PUBLIC cannot execute transaction RPC
- authenticated direct RPC deny
- valid Edge server flow pass
- Cron token wrong/missing deny

### PWA idempotency
- double tap
- response lost/retry
- concurrent same operation
- same operation different payload

### conflict
- pickup has scheduled time
- papa creates mama event
- mapped mama event doesn't block papa
- family event blocks both
- unknown event behavior
- transparent event ignored

## v4 package output

最低:
- updated README
- 01 architecture
- 03 data model
- 04 security
- 07 Google
- 09 API
- 10 WP
- 11 tests
- 14 setup
- 15 DDL
- ENV
- fixtures
- `MUTATION_CONTRACT_MATRIX.md`
- `V4_CHANGELOG.md`
- `V4_SELF_CHECK.md`
- updated SOL review prompt

v4作成後は実装を開始せず、SOL再レビューへ回してください。
