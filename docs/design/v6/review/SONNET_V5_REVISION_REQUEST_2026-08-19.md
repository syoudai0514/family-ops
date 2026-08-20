# Claude Code Sonnet向け — Family Ops v4 → v5 修正依頼

対象: `family-ops-sonnet-plan-v4`

v4は前回指摘を大幅に解消しています。
ただし独立再レビュー結果は:

**REQUEST CHANGES**
P0 0 / P1 8 / P2 7 / P3 3

AI privacyはblockerにしません。
Supabase継続です。

実装は開始せず、下記をv5設計正本へ反映してください。

---

## P1-1 LINE free quota hard budget

日本のLINE Communication Plan無料枠200通/月を絶対超えない設計へ。

追加:
`private.line_quota_state`

最低:
- billing_month
- provider_limit
- provider_consumed
- local_counted_success
- last_provider_refresh_at
- updated_at

`notification_outbox`:
- priority critical/normal/reminder
- quota_fallback_allowed

Policy:
- LINE quota + consumption APIを定期refresh
- soft budget 180
- reserve 20
- hard limit provider reported value
- reminderはsoft budget超過でin-app fallback
- criticalはreserve使用可
- hard limit後pushしない
- quota exhaustedはdead扱いしない
- immediate interactionはreply token validならreply message優先

31日全reminder未完了でもLINE counted pushが200以下になるtestを追加。

---

## P1-2 permanent LINE identity mapping

追加:
`private.line_user_links`

- id uuid PK
- household_id
- user_id
- line_user_id
- status active/unlinked
- linked_at
- unlinked_at
- created_at/updated_at
- UNIQUE(user_id) MVP
- UNIQUE(line_user_id)
- composite FK household/user

line link token claimとmapping createをsame transaction。

verified LINE webhook source.userIdからのみactor derive。

---

## P1-3 missing private schemasを完全定義

v5はstandalone packageにする。

exact schemaを03/15へ追加:
- private.webhook_inbox
- private.pending_actions
- private.raw_inputs
- private.household_invites
- private.line_link_tokens

各tableについて:
- PK
- status
- household/actor FK
- payload
- operation id
- timestamps
- lease fields
- attempts/backoff
- TTL
- unique
を固定。

`Other existing private tables retained`だけで済ませない。

---

## P1-4 Edge -> DB transaction RPC pathを成立させる

1方式に固定。

採用方式:
**server transaction entry RPCはpublic schemaへ置き、service_roleのみEXECUTE。**

例:
`public.server_tx_create_task`

Migration:
- REVOKE EXECUTE FROM PUBLIC,anon,authenticated
- GRANT EXECUTE TO service_role
- SECURITY INVOKER
- Edgeはservice-role supabase-js RPCでcall

private schema:
- Data API exposedしない
- browser grantsなし
- service_roleには必要なUSAGE/table privilege
- private helperはserver RPC内部からのみ

SECURITY DEFINER helperが必要な場合のみempty search_path。

Tests:
anon/authenticated direct RPC deny、Edge service role pass。

---

## P1-5 Household setup mutationsを18へ追加

### create-household
- JWT user
- operation_id
- user not already member
- household/profile/membership atomic
- receipt replay

### create-household-invite
- same HH adult
- operation_id
- 256-bit token
- DB hash only
- TTL=24h
- raw token one-time response only

### join-household
- JWT
- operation_id
- hash lock
- unused/unexpired
- no existing household
- max adult=2
- membership create
- token consume same transaction

Concurrency/replay tests。

---

## P1-6 Google OAuth state schema

追加:
`private.google_oauth_states`

- state_hash PK
- household_id
- user_id
- return_to nullable allowlisted
- created_at
- expires_at
- used_at
- composite FK HH/user

TTL=10m。
single-use transactional claim。

OAuth startはrandom state生成。
DBはhash only。
callbackはlock/use。

PKCEを採用するなら明記してverifier保存。
採用しないなら「confidential web-server client + state、PKCEなし」と明記し、選択肢を残さない。

---

## P1-7 Google exact sync/projection/staging contract

### Canonical initial
events.list:
- singleEvents=false
- showDeleted=true
- maxResults=2500
- no timeMin/timeMax/orderBy/q/private/shared extended filter
- all pages
- nextSyncToken

### Canonical incremental
same fixed params + syncToken。
token update final success only。

### Rolling projection
**local RFC5545 expansion禁止。**
別 events.list:
- singleEvents=true
- showDeleted=false
- timeMin=windowStart
- timeMax=windowEnd
- orderBy=startTime
- maxResults=2500
- paginate
- no syncToken

### staging
`private.google_event_staging`
- sync_run_id
- calendar_connection_id
- google_event_id
- event_json jsonb
- received_at
- PK(sync_run_id,google_event_id)

410:
all pages staging -> one reconcile tx -> next sync token。

query snapshot tests追加。

---

## P1-8 busy-member composite FK

`calendar_event_occurrences`:
- UNIQUE(household_id,calendar_connection_id,occurrence_key)

`calendar_occurrence_busy_members`:
- FK `(household_id,calendar_connection_id,occurrence_key)`
  -> occurrence same triple
- FK `(household_id,user_id)` -> household_members

Cross-household mismatch DB test追加。

---

# P2も反映

1. materialize-recurring timezone:
   - Family Ops MVPはAsia/Tokyo固定を推奨。
   - 固定するならhousehold timezone変更UI/DST generic testをMVPから削除。
   - multi-timezone維持ならevery-10m due-local dispatcher + daily receipt。
   - どちらか1つに固定。

2. retention:
   - google_sync_jobs done 14d/dead 90d
   - google_write_operations minimum 90d
   - line quota state 3 months程度

3. backup health:
   MVPではSupabase backup-health-check cron削除を推奨。
   GitHub Action内:
   - dump
   - age encrypt
   - R2 upload
   - R2 HEAD/size/hash verify
   - failure = workflow fail
   monthly manual restore。
   In-app backup statusを残すなら正規table/APIを作る。

4. Google scopes exact:
   - calendar.events
   - calendar.calendarlist.readonly
   をMVP standardとする。
   target selectionはCalendarList list。

5. manual busy classification:
   projection row直接だけでなくpersistent classification modelを追加し、
   projection rebuild後に再適用。
   recurring instance override semanticsを固定。

6. auth user deletion:
   MVP account/member hard delete unsupportedと明記。
   historical actor FKを壊さない。

7. household active adults max=2をjoin transactionでlock/check。

---

# P3 cleanup

1. ordinary deleted tombstone retentionを固定。
推奨30日。

2. weekly preflight idempotency:
`receipt or deterministic key`を削除して1方式固定。

3. `dispatch_slot_key` exact format + same-day schedule edit behavior固定。

---

# v5 package requirements

最低:
- README
- 00 scope
- 01 architecture
- 03 data model
- 04 security
- 06 LINE
- 07 Google
- 09 API
- 10 WP
- 11 tests
- 12 cost/observability
- 14 setup
- 15 DDL
- 17 routine LINE
- 18 mutation contract
- fixtures:
  - RLS
  - LINE quota
  - LINE link
  - queue recovery
  - token
  - calendar sync
  - mutation idempotency
- V5_CHANGELOG.md
- V5_SELF_CHECK.md
- SOL_REVIEW_PROMPT.md

v5作成後は実装開始せずSOL再レビューへ。
目標: **P0=0 / P1=0**。
