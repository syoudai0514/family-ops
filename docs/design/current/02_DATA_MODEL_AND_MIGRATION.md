# 02. Data Model and Migration Strategy

## 1. Scope

本書は実装前のschema semanticsを定義する。DDLそのものは作らない。

原則:

- production data delete禁止
- `supabase db reset`前提禁止
- existing migration rewrite禁止
- additive migration優先
- backfillはidempotent
- old/new truthを長期間dual-writeしない
- cutover前にcompatibility readを用意
- rollbackはphase別に定義し、**new-only semantic state発生後にlegacy current-truth readへ戻さない**

CURRENT v6のhousehold/membership/security/Google credential private modelは原則維持する。

## 2. Existing tables — keep / evolve / retire semantics

| Current table | Design action | Notes |
|---|---|---|
| households/profiles/household_members | KEEP | family_role等のcurrent extensionsを維持 |
| task_definitions | EVOLVE | expectation/carryover defaults等を追加 |
| recurrence_rules | EVOLVE | existing effective datingを利用、assignment mode拡張 |
| task_instances | EVOLVE | assignment mode/source/claim/attention/revisionを追加 |
| task_subtask_instances | KEEP/EVOLVE | current semantics維持 |
| task_events | KEEP | append-only auditを拡張 |
| requests | EVOLVE | logical request/provenanceへ寄せ、execution completion truthを廃止方向 |
| handovers | EVOLVE or compatibility façade | share/handover共通info semanticsを追加 |
| user_notifications | KEEP | in-app notification recordとして活用 |
| notification outbox/private delivery tables | KEEP | policy/intent metadataを拡張 |
| routine_checkin_sessions/items | KEEP | reconciliation sourceとは分ける |
| Google connection/cache/projection/private queue | KEEP | transport/sync canonical cacheを維持 |

## 3. Task definition additions

`task_definitions`へ概念追加候補:

- `default_expectation` check (`required`,`normal`,`optional`) default `normal`
- `carryover_policy` check:
  - `occurrence_ends`
  - `until_done`
  - `until_deadline`
  - `separate_next_occurrence`
- `duplicate_sensitivity` check (`normal`,`avoid_duplicate`,`safety_critical`) default `normal`
- `early_completion_policy` check (`none`,`recommended`,`required_before`) default `none`
- optional `default_duration_minutes`

理由:

これらは毎occurrenceで変わり得るため、materialization時にtask instanceへsnapshotする。

薬、迎え、購入、提出等のduplicate-sensitive behaviorをcategory名のhard-codeで判定しない。

## 4. Recurrence rule evolution

CURRENT `assignee_strategy`を既存互換のまま残しつつ、将来の表現を明確化する。

### 4.1 Rule assignment result

materialization結果はtask instanceへ:

- `assignment_mode`
  - `person`
  - `unassigned`
  - `anyone`
- `planned_assignee_actor_ref_id` nullable — new canonical assignment identity
- legacy `planned_assignee_id` nullable — production real-user compatibility mirror only
- `assignment_source='rule'`

をsnapshotする。

既存`fixed/dropoff_assignee/pickup_assignee/nonpickup_adult/unassigned`はruleのresolution strategyとして維持可能。

`誰でもOK`用にrule strategy `anyone`を追加する場合:

- planned assignee actor refはnull
- materialized `assignment_mode=anyone`

### 4.2 Protected future occurrence

future occurrenceにexplicit agreement/manual overrideが入った場合:

- `assignment_source != rule`
- recurrence recalculation対象から外す

rule change処理は`task_instance.assignment_source='rule'`のみ更新可能。

## 5. Task instance evolution

`task_instances`へ追加するoperational snapshot:

- `assignment_mode text not null` (`person`,`unassigned`,`anyone`)
- `assignment_source text not null`
- `planned_assignee_actor_ref_id uuid null`
- `active_claimant_actor_ref_id uuid null`
- legacy `planned_assignee_id` / proposed legacy claim user mirrorはproduction compatibility only
- `claimed_at timestamptz null`
- `expectation text not null`
- `carryover_policy text not null`
- `duplicate_sensitivity text not null`
- `early_completion_policy text not null`
- `available_from timestamptz/date null`
- `target_at/due_at` current column reuse
- `attention_state text not null default 'active'` (`active`,`waiting`)
- `waiting_note text null`
- `next_check_at timestamptz null`
- `outcome_reason text null` (`not_needed_this_occurrence`,`could_not_do`,`expired_occurrence` when status=`skipped`)
- `revision bigint/int not null default 1`
- optional `event_id uuid null`
- `test_context_id uuid null`
- optional `source_context jsonb` only for non-secret IDs/provenance pointers

Constraints:

- `assignment_mode=person` -> planned_assignee_actor_ref_id non-null
- `assignment_mode in (unassigned,anyone)` -> planned_assignee_actor_ref_id null
- active claimant allowed only when `assignment_mode=anyone` and status operationally open
- completed/cancelled task cannot have active claimant
- `attention_state=waiting` allowed only when status in (`todo`,`in_progress`)
- terminal transition clears current waiting metadata while audit preserves history
- `outcome_reason` is null unless status=`skipped`; skipped must have a recognized reason for new writes
- production row (`test_context_id is null`) cannot reference simulated ActorRef
- test row may reference simulated ActorRef only from the same `test_context_id`

`actual_completed_by_id`はnew truthとして使用しない。compatibility期間は残す。

## 6. Assignment and claim audit

current assignment/claimはtask instance snapshotを正とし、historyはappend-only。

`task_assignment_events`を新設するか`task_events`のevent_type/payloadを拡張する。

推奨は**既存`task_events`拡張**。不要なparallel audit tableを増やさない。

新event type例:

- `assignment_changed`
- `assignment_agreed`
- `claim_acquired`
- `claim_released`
- `claim_taken_over`
- `assignment_rule_recomputed`
- `actual_corrected`
- `waiting_started`
- `waiting_updated`
- `waiting_resumed`

payload:

- from/to assignment mode
- from/to assignee/claimant ActorRef
- source
- request/attempt reference
- attention before/after when applicable
- revision before/after

## 7. Domain actor identity

One-user testとproductionでdomain state machineを共有しつつidentity truthを汚さないため、新規 `domain_actor_refs` を全actor-bearing semanticsの共通参照点とする。

### `domain_actor_refs`

- `id uuid PK`
- `household_id uuid not null`
- `actor_kind text not null` (`real_user`,`simulated_member`,`system`)
- `real_user_id uuid null`
- `test_context_id uuid null`
- `simulated_role text null` (`papa`,`mama` initially)
- `created_at`

Invariants:

- `real_user` -> same-household `real_user_id` required; test_context/simulated_role null; unique `(household_id,real_user_id)`
- `simulated_member` -> `test_context_id + simulated_role` required; real_user_id null; unique `(test_context_id,simulated_role)`
- `system` -> no real/simulated user identity; household-scoped stable row or equivalent server actor
- simulated ActorRefはreal `household_members` row/auth userを要求しない
- test contextとActorRefのhousehold一致をFK/transactionで強制する

Canonical actor-bearing fieldsはActorRefを使う。対象:

- planned assignee
- anyone claimant
- actual performer
- recorder
- request requester/recipient/created-by
- request confirmation
- reconciliation actor
- task/audit actor
- source uploader/confirmed-by/resolved-by where actor semantics matter

既存user-id FK列はproduction real-user compatibility mirrorとして段階的に残せるが、simulated actorをoperator user IDで代用しない。

## 8. Multiple actual performers

新規 `task_actual_participants`:

- `household_id`
- `task_instance_id`
- `actor_ref_id`
- `participation_kind` default `performed`
- `recorded_by_actor_ref_id`
- `recorded_at`
- optional `removed_at` for correction history or use append-only correction event
- unique active `(task_instance_id,actor_ref_id)`

Task completionのcurrent truth:

- `task_instances.status=completed`
- `task_instances.completed_at`
- participant rows >= 1 when a known household actor performed

「誰がやったか不明だが完了確定」の特殊caseを許すかは要求上必須ではないため、通常completionはperformerを少なくとも1人要求する。system migration/backfillでlegacy completion actorがnullの既存データは`legacy_unknown_performer`としてhistory上識別し、無理に推測しない。

### 8.1 Legacy `actual_completed_by_id`

migration path:

1. ActorRef/participant tableをadd。
2. existing non-null `actual_completed_by_id`のreal-user ActorRefを作成/再利用しparticipantへidempotent backfill。
3. new completion pathはparticipant ActorRefへ書く。
4. compatibility期間のみ、production real participantなら`actual_completed_by_id`へprimary real userをmirrorしてold readsを壊さない。
5. simulated/test participantはlegacy real-user列へmirrorしない。
6. all reads cutover後にlegacy columnをdeprecated扱い。physical dropは別future migrationでreviewする。

mirror期間でもtruthはparticipant table + task statusと明文化する。

## 9. Group reconciliation evidence

`大体やった`をtask statusへ入れないため新規:

### `task_reconciliation_sessions`

- id
- household_id
- `actor_ref_id`
- target_local_date
- group_key (`morning`,`evening`,`bedtime`, custom stable key)
- response_kind (`all_done`,`mostly_done`,`individual`)
- source (`line`,`pwa`)
- `test_context_id` nullable
- created_at
- supersedes_session_id nullable

### `task_reconciliation_session_items`

- household_id
- session_id
- task_instance_id
- observed_status_at_response
- display_order
- primary key/unique `(session_id,task_instance_id)`

Purpose:

- どのtask集合に対して回答したかsnapshotする
- 後から同groupへtaskが追加されても過去の`大体やった`で勝手にcoveredにしない
- `mostly_done`はchild statusを変更しない
- reconciliation prompt抑制にのみ使う

`all_done`ではeligible child tasksをtransaction内でcompleteしたうえでsessionも記録する。

## 10. Request / attempt model

### 10.1 `requests` — logical identity

既存tableをevolveする。

New canonical identity fields:

- id/household_id
- `requester_actor_ref_id`
- `recipient_actor_ref_id`
- legacy requester_id/recipient_id — production real-user compatibility mirror only
- `request_kind` (`light`,`assignment_change`)
- shared_title/shared_message
- linked_task_instance_id nullable
- assignment_task_instance_id nullable
- created_at
- `closed_at` nullable only when whole logical request no longer needs future attempts
- `test_context_id` nullable

legacy `status/accepted_at/declined_at/completed_at/cancelled_at`はcompatibility期間保持するが、new runtime truthには使わない。

Production requestはreal-user ActorRefのみ。Test requestはsame test contextのsimulated/real ActorRef combinationを許すがproduction user-id columnsへfake mirrorしない。

### 10.2 `request_attempts`

- id
- household_id
- request_id
- attempt_kind (`initial`,`reproposal`,`change`,`cancel`)
- state:
  - `pending`
  - `checking`
  - `consulting`
  - `awaiting_confirmation`
  - `accepted`
  - `declined`
  - `expired`
  - `cancelled`
- `terms_revision int`
- `terms jsonb`（期限/担当/scope等、partner-visible confirmed data only）
- `reply_due_at`
- `created_by_actor_ref_id`
- accepted/declined/expired/cancelled timestamps
- `revision`
- `test_context_id` nullable inherited from request

per request:

- active nonterminal attemptは最大1件
- accepted initial/reproposal establishes agreement
- accepted change/cancel updates linked task/assignment atomically

### 10.3 Consultation confirmation

新規 `request_attempt_confirmations`:

- attempt_id
- terms_revision
- `actor_ref_id`
- confirmed_at
- unique(attempt_id,terms_revision,actor_ref_id)

consultingのterms変更時にrevision incrementし、旧confirmationは新revisionに効かない。

双方のrequired actor refsが同revisionをconfirmした時だけaccepted。

### 10.4 Late/stale action

LINE/PWA actionは:

- request_id
- attempt_id
- terms_revision or expected revision

を含む。

closed/expired attempt actionは`REQUEST_ATTEMPT_STALE`でcurrent attempt/linkを返す。自動復活禁止。

## 11. Share / handover model

既存`handovers`をいきなりrenameしない。

additive extension案:

- `info_kind` (`share`,`handover`) default existing rows=`handover`
- `visibility` (`household`,`self`)
- `valid_from`
- `valid_until`
- `ack_policy` (`none`,`required`)
- related_task_id/event_id nullable
- `status` (`active`,`superseded`,`expired`)
- `supersedes_handover_id` nullable
- actor-bearing author/ackはActorRef canonicalへ移行可能

`handover_reads`はack receiptとしてreuse可能。ただし`ack_policy=none`でもread trackingを必須にはしない。

## 12. Family event model

新規 `family_events`:

- id
- household_id
- title
- status (`active`,`waiting_reschedule`,`cancelled`)
- starts_at/ends_at or all-day dates
- location/details nullable
- `calendar_visibility` / sync preference
- `revision`
- `created_by_actor_ref_id`
- created_at/updated_at
- `test_context_id` nullable

prep taskは`task_instances.event_id`でlink。prep taskの`待ち`はTask attention stateを使い、event statusへ混ぜない。

### 12.1 Field authority

過剰なEAVを避けるためeventごとに:

- `field_authority jsonb`

を持つ。許可fieldのみkeyとして使用:

- title
- starts_at/ends_at/all_day
- location

value例:

```json
{
  "starts_at": {"mode":"human_protected","source":"manual","revision":3},
  "title": {"mode":"external_follow","source":"google","revision":1}
}
```

arbitrary user dataをkey/valueに入れない。schema validationをserver側で行う。

## 13. Google link and sync baseline

新規 `family_event_external_links`:

- household_id
- family_event_id
- provider=`google`
- calendar_connection_id
- google_event_id
- link_mode (`family_ops_owned`,`external_follow`)
- `last_external_snapshot jsonb`（owned fields only）
- `last_external_etag`
- last reconciled timestamps
- unique(provider,calendar_connection_id,google_event_id)

Google canonical cacheそのものは既存tableを継続利用する。

## 14. Generic change candidates

新規 `change_candidates`:

- id
- household_id
- target_type (`family_event`,`task`,`recurrence`,`info`)
- target_id nullable for create candidate
- source_type (`google`,`image_fact`,`ai_inference`,`manual_import`)
- source_ref
- `proposed_patch jsonb`
- `current_snapshot_hash`
- `status` (`pending`,`accepted`,`rejected`,`superseded`,`stale`)
- created_at/resolved_at/`resolved_by_actor_ref_id`
- `revision`
- `test_context_id` nullable

Rules:

- candidate acceptance時にtarget current revision/hashを再確認。
- staleならsilent applyせずrebase/review。
- `ai_inference`はcandidate経由以外でcurrent entityを変更しない。

## 15. Children / school context

既存に子どもdomainが不足しているため新規:

### `family_children`

- id
- household_id
- display_name
- active
- created_at

### `child_school_contexts`

- id
- household_id
- child_id
- school_display_name
- class_display_name
- effective_from/effective_to
- recognition_aliases text[]（ユーザー確認済みのみ）
- active

マサキ/すだちぐみ、ウタノ/ゆきぐみを**別school context**として登録可能にする。

別園であることをschool context IDで分離し、同名classだけでmergeしない。

## 16. Nursery/Codmon source documents

### `source_documents`

public browser direct readではなくRLS/private storage metadataを設計。

- id
- household_id
- `uploaded_by_actor_ref_id`
- document_kind
- storage_object_key
- captured_at/uploaded_at
- `raw_deleted_at` nullable
- `retention_policy`
- `test_context_id`

### `document_extractions`

- id
- source_document_id
- extraction_version
- model/provider metadata (no secret/raw prompt)
- target school-context candidate
- status (`processing`,`review`,`confirmed`,`rejected`,`failed`)
- created_at

### `document_facts`

persistするのは家庭に関係するfactのみ。

- extraction_id
- child_school_context_id nullable until confirmed
- fact_kind (`event`,`required_item`,`deadline`,`recurrence`,`url`,`note`)
- normalized_value jsonb
- confidence band
- source locator/page/image index
- `fact_origin='source_explicit'`

他児童名一覧等の全文OCR transcriptをdurable public business tableへ保存しない。

### `school_preparation_rules`

- household_id
- child_school_context_id
- trigger_kind/value
- preparation template
- `confirmed_by_actor_ref_id`
- effective_from/effective_to
- active

AI inferenceだけでrow作成しない。user-confirmedのみ。

## 17. Test context

新規 `test_simulation_contexts`:

- id
- household_id
- operator_user_id
- simulated_role (`mama` initially)
- status (`active`,`closed`)
- created_at/closed_at

business records created by simulated actorには`test_context_id`またはtest-scoped aggregateを必須にする。

原則production analytics queryは`test_context_id is null`を既定とする。

simulated actor用にfake auth userを作らない。実user/household membershipとの混同を防ぐ。

Actor representationはSection 7の`domain_actor_refs`を唯一の永続identity modelとする。command contextはActorRefを解決するための入力であり、永続化の代替ではない。

## 18. Notification intent evolution

既存`user_notifications`/outboxを利用しつつ、domain intent情報を追加する。

必要metadata:

- `notification_kind`
- `urgency` (`immediate`,`digest`,`in_app_only`)
- `safety_class` (`normal`,`duplicate_sensitive`,`critical`)
- `bundle_key`
- `business_expires_at`
- `test_context_id`

production outboxへ入れられるのは`test_context_id is null`のみ。

synthetic test deliveryはseparate adapter pathでoperator destinationを強制する。

## 19. Daily Brief read model

物理tableとして永続化する必要はない。server RPC/viewがcurrent stateから生成する。

`DailyBrief` minimum shape:

- generated_at/local_date/daypart
- urgent_actions[]
- exceptions[]
- active_infos[]
- burden_reducing_completed[]
- own_task_groups[]
- partner_summary
- carryovers[] with `result_certainty`
- `waiting_checks[]` with task ID, note summary, next_check_at, deadline risk
- reconciliation_prompt
- schedule/calendar status
- deep_link targets

LINE/PWAはこのshapeをrenderする。

Waiting behavior:

- future next-check waiting taskはnormal incomplete list/nagから除外
- next_check_at到来/超過で`waiting_checks`へ再浮上
- hard due riskはnext_check_atより優先して`urgent_actions`へ出せる
- read生成がattention_stateを勝手にactiveへ変更しない

## 20. Migration phases

### Phase 0 — docs/design only

本PR。runtime変更なし。

### Phase 1 — additive schema

- add ActorRef + new columns/tables
- no existing behavior cutover
- RLS/FK/check indexes
- compatibility views/helpers
- migrations timestamp順、既存migration変更禁止

**Rollback class R0:** new writes未開始なのでold runtimeへ完全に戻せる。schema additionsは残ってもよい。

### Phase 2 — deterministic backfill

- real household actor refs backfill
- actual participant backfill
- request attempt backfill
- assignment mode/source backfill
- existing handover defaults
- existing tasks expectation/carryover defaults
- legacy request/task mismatch report

backfillは再実行safe。推測禁止。

**Rollback class R0:** canonical runtime still old; backfill rows can be ignored/forward-fixed。

### Phase 3 — new command path behind feature gate

household/user feature flagでnew semanticsへ切替可能にする。

ただし1aggregateについてold/new mutationを同時に自由利用させない。request切替後はold accept/decline pathをnew command adapter経由へ向ける。

Test ActorRef + execution context + production side-effect hard guardは、actual household one-user testより前にこのphaseで必須。

**Point of no return P1:** checking/consulting/anyone claim/multiple performer/waiting/mostly-done等のnew-only semantic stateを最初に生成した時点。P1後はlegacy current-truth readへのrollback禁止。

### Phase 4 — shared read model cutover

- PWA Today -> DailyBrief
- LINE Today/digest -> DailyBrief
- Request UI -> new attempt state
- History -> new participant/evidence semantics

P1後の障害時fallbackはcanonical new truthからのcompatibility projection/read-only degraded UIを使う。old semanticsを再びtruthとして読ませない。

### Phase 5 — legacy write retirement

- request.completed direct writes停止
- `actual_completed_by_id` primary truth利用停止
- legacy endpoints return/route to new commands

physical column removalは別reviewed cleanup migrationまで行わない。

## 21. Backfill rules

### 21.1 Actor refs

existing household memberごとにreal-user ActorRefをidempotent作成する。

- same household/user -> same actor ref
- operatorとfuture real spouseを別ActorRefとして保持
- existing production dataをsimulated actorへ変換しない

### 21.2 Task assignment

existing planned_assignee_id non-null -> corresponding real-user ActorRef + `assignment_mode=person`, `assignment_source=legacy_snapshot`。
null -> task kind/ruleから**明確にunassignedと証明できる場合のみ**unassigned。誰でもOKは既存データから推測しない。

### 21.3 Actual participants

existing actual_completed_by_id -> corresponding real-user ActorRef participant。
completed but null -> no fake participant。legacy unknown markerをaudit/compatibility fieldで扱う。

### 21.4 Requests

Basic deterministic mapping:

- pending -> active initial attempt pending
- accepted -> accepted initial attempt; linked taskをexecution truth
- completed -> accepted attempt + linked task current completionを利用
- declined -> declined attempt
- cancelled -> cancelled attempt

**Cutover precondition reconciliation report** must detect at least:

- missing linked task for accepted/completed request
- duplicate/invalid linked task relation
- legacy request terminal state vs linked task state mismatch (e.g. completed request + todo task, accepted request + cancelled task)
- accepted/completed/cancelled timestamps inconsistent with linked task timeline where deterministically checkable

Anomaly rowはmigration audit issueとして隔離し、推測task作成・推測completion・自動片寄せをしない。対象household/rowが解決またはexplicit legacy-unknown treatmentに分類されるまでsemantic cutover gateを通さない。

### 21.5 Task outcome reason

Existing `skipped`はlegacy dataだけから`not_needed`/`could_not_do`を推測しない。reason不明なら`legacy_unknown_outcome` compatibility classificationとして扱い、新writeからrecognized `outcome_reason`を必須化する。

### 21.6 Test data

existing production dataをtest扱いへ再分類しない。new test mode開始以降のみexplicit test contextを持つ。

## 22. Index/constraint expectations

詳細DDL時に最低限:

- ActorRef kind-specific CHECK/FK/unique
- production aggregate cannot reference simulated ActorRef
- test aggregate ActorRef test_context equality
- active request attempt unique per request
- active anyone claim consistency
- participant active uniqueness
- reconciliation session item FK
- source doc -> extraction -> fact composite household isolation
- event external link uniqueness
- candidate target/source indexes
- test_context leakageを防ぐ FK/check
- RLS household isolation
- service-role-only mutation RPC privileges

を設計レビューする。

## 23. No destructive shortcut

実装時に以下を禁止する。

- old request rows一括削除
- completed historyの書換え
- recurrence historyのcollapse
- raw nursery image cleanupと同時にconfirmed structured data削除
- Google cacheをfamily event truthへ直接流用
- test simulated recordsをproduction spouse identityへupdate
- P1後にlegacy readをcurrent truthとして復活
- simulated actorをoperator real userとして保存