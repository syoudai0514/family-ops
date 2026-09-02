# 01. Architecture and Domain Boundaries

## 1. Purpose

本書はcanonical Requirements & UX Baselineを、CURRENT implementationを最大限再利用しつつ安全に実装するためのarchitecture boundaryを定義する。

設計対象は新機能の「画面案」だけではない。今回の核心は、同一家庭作業に複数のtruthが生まれないよう、**誰が何の正を持つか**を固定することである。

## 2. Normative hierarchy

ADR 0012に従う。

1. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
   - requirements / UX / product behaviorの正。
2. Accepted ADRs
   - architecture/security/API等の明示決定。
3. 本 `docs/design/current/*`
   - 独立レビュー後に次期詳細設計の正となる候補。
4. `docs/design/v6/*`
   - 上記と非競合な既存architecture/security/API/operational constraintで有効。
5. code/tests
   - 上記へ従う。実装が暗黙にproduct behaviorを定義しない。

本設計でv6とarchitecture/API/schema/security上の差分を意図的に導入する箇所はADR 0013でscopeを明示する。

## 3. CURRENT implementationから維持する骨格

CURRENT mainには以下の実装資産があり、全面書換えは行わない。

- Supabase Auth + household membership / RLS-safe read model
- Edge Functionをuser mutation boundaryとする構成
- `public.server_tx_*` transaction RPC pattern
- `private.mutation_receipts` によるoperation-level idempotency
- `task_definitions` / `recurrence_rules` / `task_instances`
- `task_events` append-only audit
- requests / handovers / shopping / notifications
- LINE webhook durable inbox + worker
- pending action preview/confirm pattern
- notification outbox + LINE dedup/retry/quota protection
- routine materialization/check-in sessions
- Google OAuth / sync queue / canonical cache / occurrence projection / ETag write guard
- PWA Today / Requests / History / Settings等の既存feature shell

再利用方針は「既存列を無条件に正とし続ける」ではない。**transport/security/queue/auditの強い既存基盤を再利用し、Baselineと衝突するdomain semanticsだけを再整理する。**

## 4. Architecture style

### 4.1 Command side

すべてのbusiness mutationは原則:

`PWA or LINE -> Edge Function -> server_tx_* -> DB state + audit + notification intent -> commit`

とする。

- PWAとLINEで別mutation logicを作らない。
- LINE postbackもPWA buttonも同じcommand contractへ収束する。
- user-origin mutationは`operation_id`必須。
- provider/worker-origin eventはprovider event ID / job ID / deterministic business keyでidempotentにする。
- transaction内でcurrent state、audit event、notification intentを不整合に分けない。

### 4.2 Query side

Daily UXはfrontendごとに再構成しない。server-side read modelを共有する。

主要read model:

- `DailyBrief`
- `TaskDetail`
- `RequestDetail`
- `EventDetail`
- `IntakeReview`
- `HistoryView`

特に`DailyBrief`をLINE morning/evening、LINE `今日`、PWA Todayの共通入力にする。

### 4.3 Event/audit side

`task_events`等のappend-only auditは「現在状態の代替」ではない。

- current state: operational table
- history/provenance: append-only event

と分ける。

イベントを毎回replayしてcurrent stateを算出するevent sourcingへは移行しない。家庭向け規模で過剰設計になるためである。

## 5. Truth ownership matrix

| Concern | Canonical current truth | History/provenance | Derived only |
|---|---|---|---|
| Task operational status | `task_instances` | `task_events` | UI label |
| Planned assignment | task instance effective assignment snapshot | assignment audit/event | base rule display |
| `誰でもOK` active claim | task instance active claim snapshot | claim events | display `対応中` |
| Actual performers | confirmed participant rows | task events/corrections | support analytics |
| Group `大体やった` | reconciliation session | reconciliation audit | child status must not derive completion |
| Recurrence rule | current effective rule row/version | supersession chain | future occurrence generation |
| Individual agreement | accepted request/assignment agreement record | attempt history | current task assignment if applied |
| Request negotiation | current request attempt | prior attempts | display status |
| Accepted request execution | linked task | request provenance | request “完了” display |
| Share/handover active info | info record + validity | edits/ack history | Today section |
| Family event | Family Ops event record | field/source revisions | Google projection |
| Google external state | Google canonical cache | sync audit | candidate vs current comparison |
| Nursery source fact | confirmed extraction fact/candidate state | source document/extraction | generated prep suggestion |
| AI inference | candidate only | proposal log | never current truth without confirm |
| Test simulated consent | test-scoped agreement only | test audit | never real spouse consent |

## 6. Task domain boundary

`task_instances`を「1回の家庭作業」のoperational aggregate rootとして維持する。

Task aggregateが責任を持つもの:

- title/category
- target/scheduled date
- due window
- carryover policy
- expectation (`required/normal/optional`)
- assignment mode/current effective assignment
- anyone claim
- operational status
- linked event/request/source references

Task aggregateが責任を持たないもの:

- recurrence definitionそのもの
- request negotiation state
- raw source image
- Google remote event resource
- group reconciliation evidence

### 6.1 Assignment modes

current taskは次の3modeに閉じる。

- `person`: specific planned assigneeあり
- `unassigned`: 担当決定が必要
- `anyone`: 担当決定不要、実施前claimが必要

`claim`はassignment modeを`person`へ変えない。`anyone`のままactive claimantを持つ。

これにより「誰でもOKをパパがclaimしただけなのに、パパ担当へ正式変更された」誤解を防ぐ。

### 6.2 Assignment provenance

UI上のcurrent assigneeは1つに見せるが、内部で`assignment_source`を保持する。

代表値:

- `rule`
- `manual_once`
- `period_override`
- `agreement`
- `setup_default`

future recurrence recalculationは`assignment_source=rule`由来のfuture taskだけを更新対象にする。`agreement/manual/override`はprotected occurrenceとして再計算から外す。

## 7. Actual domain boundary

planned assignmentとactual performerを同じ列/状態で表さない。

- task completion = household workが完了した事実
- performer = その仕事に実際に関与した人（複数可）
- recorder = 完了事実を登録したactor

completion correctionでplanned assignmentを書き換えない。

`担当外サポート`は保存するmanual flagではなく、completion時点のassignment provenanceとperformerを比較してderived判定する。

例外:

- assignment mode=`anyone` -> support扱いしない
- assignment変更成立後に新担当が実施 -> support扱いしない
- planned=mamaのままpapa実施 -> papa support
- planned=mama、papa+mama実施 -> papa joint support、household completionは1件

## 8. Request / negotiation boundary

Requestをexecution taskのstatus containerにしない。

### 8.1 Request

安定した依頼identity/provenance。

- requester / recipient
- kind (`light_request` / `assignment_change`)
- original/shared wording
- execution target / linked task
- created source

### 8.2 Attempt

交渉の1回分。

- initial proposal / modification / cancellation / reproposal
- reply deadline
- current terms/revision
- `pending/checking/consulting/awaiting_confirmation/accepted/declined/expired/cancelled`

期限超過後のlate actionはclosed attemptを復活させず、新attemptへ進む。

### 8.3 Accepted execution

accepted後の:

- completion
- reschedule
- skipped/not-needed
- cancellation of work

はlinked ToDoのtruth。

Requestは「依頼が何だったか / 何に合意したか」を保持する。

## 9. Recurrence boundary

Recurrence ruleはfuture occurrence generatorであり、past/current taskのtruthではない。

- ruleにeffective_from/effective_to/versionを持つ既存方針を維持。
- materialized taskへresolved assignmentをsnapshot。
- rule変更はstable logical occurrence keyを維持。
- explicit individual agreement / override済みfuture occurrenceはrule再計算から保護。
- 同scopeのprotected occurrencesはbulk確認可能なread modelを作る。

## 10. Information / handover boundary

共有と引き継ぎは同じ通知ではない。

共通aggregateは情報recordとして扱えるが、最低限:

- kind (`share` / `handover`)
- visibility (`household` / `self`)
- valid_from/valid_until
- acknowledgement policy (`none` / `required`)
- related task/event

を持つ。

`acknowledged`と`task completed`を別truthにする。

## 11. Event boundary

Family Opsが扱う「予防接種」「七五三」「園行事」等は、Google cache rowを直接canonical family eventにしない。

Family Ops側に`family_event` aggregateを置き:

- event current value
- linked prep tasks
- source/protection metadata
- external Google link

を管理する。

Google eventはexternal representation/sourceとして扱う。これによりGoogle delete/changeをFamily Ops eventのsilent deleteへ直結させない。

## 12. Source / candidate boundary

Google change、nursery image fact、AI inferenceを個別overwriteルールで実装しない。

共通概念:

- **current effective value**
- **source observation/fact**
- **candidate change**
- **authority/protection metadata**
- **human resolution**

AI inferenceは必ずcandidate。

nursery imageの「文書に明記」はAI inferenceより強いsource factだが、人が既にprotectedにしたcurrent valueを自動上書きしない。

## 13. Notification boundary

Domain mutationとLINE provider deliveryを分離する。

1. transactionが`notification intent`を作る
2. policy engineが`immediate / digest / in-app-only / suppress`を決める
3. rendererが現在stateを使ってmessageを作る
4. delivery outboxがproviderへ送る

`相手がやった`というactor praiseを送るか否かと、`もう実施不要`という安全stateを知らせるかは分離する。

薬等duplicate-sensitive taskはneutral `対応済み` state notificationを許可する。

## 14. Test-mode boundary

production domain modelを複製しない。

- same validation
- same state machine
- same command layer

を使うが、`execution_context=test_simulation`を必須伝播し、external adapter boundaryで副作用を変える。

allowed:

- operatorへ`🧪`付きsynthetic rendered message
- test-scoped records/events

forbidden:

- simulated actorを宛先にしたproduction LINE push
- production notification outbox
- Google write
- real spouse consent/ack
- production analytics inclusion

## 15. Concurrency boundary

すべてのmutable aggregateにcurrent revisionまたはequivalent preconditionを持たせる。

mutation requestは:

- operation id
- aggregate id
- expected revision（stale-sensitive action）

を使う。

同operation retryはidempotent replay。
別operationでexpected revisionが古い場合はlatest stateを返して再確認する。

特に:

- request postback
- assignment change
- claim/takeover
- event conflict resolution
- performer correction

でsilent last-write-winsを禁止する。

## 16. Detailed design non-goals

今回導入しないもの:

- general event sourcing
- arbitrary dependency DAG
- household score/ranking engine
- universal workflow/BPM engine
- universal EAV field store
- every UI actionを独立microservice化
- AI autonomous assignment/update

家庭運営の状態を正確にしつつ、通常操作を軽くするために必要な範囲へ限定する。
