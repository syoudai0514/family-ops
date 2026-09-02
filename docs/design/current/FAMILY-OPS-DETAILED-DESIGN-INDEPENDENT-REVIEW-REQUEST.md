# 【おうちノート / Family Ops｜DETAILED DESIGN INDEPENDENT REVIEW｜NO IMPLEMENTATION】

@GitHub

repository:
`syoudai0514/family-ops`

canonical branch:
`main`

requirements Source of Truth:
`docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`

review target:
PR head の `docs/design/current/*` および proposed ADR 0013

==================================================
0. IMPORTANT
==================================================

今回は**詳細設計の独立レビューのみ**です。

以下は禁止です。

- code変更
- CSS変更
- migration作成/変更
- commit
- PR作成/更新/merge
- Supabase変更
- Edge Functions deploy
- cron変更
- Vercel deploy
- Google Calendar実環境変更
- LINE runtime設定変更
- production data変更

最初にCURRENT GitHub `main` をfresh readしてください。
古い会話・過去PR説明・以前の設計だけを前提にしないでください。

その後、レビュー対象PRの**actual head**にある以下を全文確認してください。

1. `docs/design/current/README.md`
2. `docs/design/current/01_ARCHITECTURE_AND_DOMAIN_BOUNDARIES.md`
3. `docs/design/current/02_DATA_MODEL_AND_MIGRATION.md`
4. `docs/design/current/03_STATE_MACHINES_AND_COMMANDS.md`
5. `docs/design/current/04_LINE_PWA_DAILY_UX_AND_NOTIFICATIONS.md`
6. `docs/design/current/05_GOOGLE_IMAGE_AI_AUTHORITY_PRIVACY.md`
7. `docs/design/current/06_TEST_MODE_CONCURRENCY_OBSERVABILITY.md`
8. `docs/design/current/07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`
9. `docs/adr/0013-current-detailed-design-architecture-evolution.md`

さらにCURRENT `main` の以下を基準として照合してください。

- `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- `docs/requirements/README.md`
- `docs/adr/0012-requirements-ux-canonical-governance.md`
- `docs/adr/0001-v6-baseline-commitment.md`
- relevant `docs/design/v6/*`
- CURRENT application / Supabase schema / Edge Functions / LINE / Google implementation

過去にMarkdownがmid-UTF-8でtruncateした事故があったため、レビュー開始時に**review targetの主要Markdownがactual Git blobとして末尾まで存在し、有効なUTF-8として読めること**も確認してください。

==================================================
1. PURPOSE
==================================================

Requirements Baselineは独立レビューで `GO` 済みです。
今回はその要求を実装するための詳細設計が、

- truth ownershipを二重化しないか
- production dataを安全に移行できるか
- CURRENT architectureを適切に再利用しているか
- concurrency / stale action / notification / external source conflictを安全に扱えるか
- 不要なstate/table/architectureを増やしすぎていないか

を、実装者とは独立した立場でレビューしてください。

**要求をもう一度ゼロから作り直すレビューではありません。**
ただし詳細設計がcanonical Requirementsに違反している場合、または要求を満たすために不必要に危険・複雑な方式を選んでいる場合は、遠慮なく止めてください。

==================================================
2. NORMATIVE GOVERNANCE TO VERIFY
==================================================

ADR 0012により:

- Requirements Baseline = requirements / UX の正
- v6 = Requirementsと非競合なarchitecture / implementationで有効
- architecture/API/schema/security conflict = ADRで明示解決

となっています。

今回proposed ADR 0013は、accepted requirementsを実装するために必要な以下のarchitecture evolutionを明示します。

- Request agreement truthとlinked ToDo execution truthの分離
- single actual performerからmulti-participant actualへの進化
- assignment modeと`誰でもOK` claimの分離
- `大体やった`をgroup reconciliation evidenceとして分離
- Family Ops event + Authority/candidate layerとGoogle provider cacheの分離
- user-facing LINE cadenceのRequirements準拠化
- simulated actorのside-effect sandbox

ADR 0013のscopeが適切か、v6の有用なsecurity/provider/idempotency mechanicsまで不必要に捨てていないか確認してください。

==================================================
3. REQUIRED CROSS-CUTTING REVIEW
==================================================

### A. Truth ownership / state explosion

以下の正が1つに閉じているか確認してください。

- task operational status
- recurrence definition vs occurrence
- current assignment
- assignment provenance
- `誰でもOK` claim
- actual performer(s)
- actual recorder
- request / negotiation attempt
- accepted request execution
- group reconciliation evidence
- share/handover acknowledgement
- Family Event current value
- Google provider observation
- nursery source fact
- AI inference
- simulated consent

特に、同じ家庭作業について複数tableが独立に「完了」「担当」「合意」を持つ設計になっていないか厳しく確認してください。

### B. Request / assignment negotiation

以下を実際の状態遷移としてwalkthroughしてください。

1. pending → やる
2. pending → 難しい
3. pending → 確認してみる → やる/難しい
4. checking中にreply deadline超過
5. expired後に古いLINE `[やる]`
6. 相談する → 条件案 → 片方だけconfirm
7. 同じterms revisionを双方confirm
8. terms変更で旧confirmが無効になる
9. accepted requestのexecution taskを再予定
10. accepted後の依頼内容変更
11. accepted後の取消提案
12. oral `調整済み` → important change → `[違う]`

Requestとlinked ToDoが再び二重completion truthにならないか確認してください。

### C. Assignment / claim / actual

確認:

- `person / unassigned / anyone`が十分か
- anyone claimがformal person assignmentへ化けないか
- claimant以外が実際に作業をした時にactual truthを記録できるか
- takeoverとcompletion raceが破綻しないか
- multiple performerがhousehold completion件数を二重化しないか
- support analyticsがstored manual flagではなく安全にderivedできるか
- rule変更がexplicit agreement/manual overrideを上書きしないか

### D. `全部やった / 大体やった / 個別で答える`

Requirements Final GOで残ったMEDIUM-1を重点確認してください。

- `大体やった`はchild task statusを変えないか
- occurrence-end / until-done / until-deadline / separate-next-occurrenceが整合するか
- `結果未確認` carryoverが毎日ノイズにならないか
- carryover-sensitive subsetへのcompact follow-upが、結局「個別入力を強制するUI」になっていないか
- group reconciliation session/item snapshotは必要十分か、過剰か
- undo/concurrent mutation時にsilent overwriteしないか

### E. Daily Brief / LINE / PWA

確認:

- server-side shared `DailyBrief`は妥当か
- LINEとPWAでbusiness logicが分岐しないか
- weekday 06:30 / weekend-holiday 09:00 / evening 20:30がRequirementsどおりか
- self tasksをLINEに全部載せてもreadabilityを保てるか
- morning/evening anchor + immediate meaningful exceptionsがnotification fatigueを増やさないか
- stale rendered messageを遅配しない仕組みが十分か
- PWA deep link/current-state restorationが自然か
- mutation後reload/scroll resetを避ける設計になっているか

### F. Duplicate-sensitive tasks — Final GO MEDIUM-2

薬、送り迎え、購入、提出等について:

- `duplicate_sensitivity`をtask policyとして持つ判断は妥当か
- category hard-codeより安全か
- neutral `対応済み` immediate stateはscorekeepingせず事故を防げるか
- old LINE/postbackを見た相手が二重投薬等を起こさないか
- LINE unavailable/quota fallbackでもPWA/current stateは正しいか
- safety classの濫用で通知が増えすぎないか

### G. Migration / legacy compatibility

CURRENT production schema/codeと照合してください。

特に:

- `task_instances.actual_completed_by_id`
- `requests.status/completed_at`
- current recurrence materialization
- task_events
- routine sessions
- notification outbox

から新設計への移行が安全か確認してください。

要求:

- existing migration rewriteなし
- resetなし
- additive schema first
- deterministic/idempotent backfill
- guessed anyone assignmentなし
- guessed performerなし
- completed request/linked task mismatchを勝手にrepairしない
- temporary compatibility mirrorがpermanent dual-truthにならない
- legacy columns physical dropはlater reviewed migration

Migration planにrollback/cutover holeがないか厳しく確認してください。

### H. Concurrency / idempotency

以下をwalkthroughしてください。

- duplicate LINE webhook
- same postback double tap
- PWAとLINE同時completion
- two adults concurrent completion
- claim vs takeover
- takeover vs completion
- request terms update vs confirmation
- request expiry worker vs accept
- candidate accept vs local edit
- Google sync update vs human candidate resolution

`operation_id`だけでは足りないbusiness uniqueness / expected revisionが適切に併用されているか確認してください。

### I. Family Event / Google Authority

今回の大きなarchitecture changeです。

確認:

- Family Event aggregate追加が本当に必要か、それとも過剰設計か
- Google cacheをprovider observationとして残す境界が明確か
- `family_ops_owned / external_follow`とfield authorityが複雑すぎないか
- three-way compareでsilent overwriteを防げるか
- protected Family Ops eventをGoogle誤操作が壊さないか
- Google-origin eventは必要な範囲で自然にfollowできるか
- Google delete/date change/duplicate linkが閉じているか
- prep task shiftがcompleted/manual/protected taskを壊さないか
- Google OAuth/watch/syncToken/ETag/idempotency等のv6強いmechanicsを維持できているか

もしgeneric `change_candidates`や`field_authority jsonb`が過剰なら、同等安全性を保つより単純な案を提示してください。

### J. Nursery / Codmon image intake

確認:

- child/school context modelがマサキ/すだち、ウタノ/ゆきを安全に分離するか
- 別園を誤mergeしないか
- source explicit factとAI inferenceがdata/UI両方で分離されているか
- third-party child infoをdurable structured dataへ残さないか
- confirmed school-preparation ruleのみ学習するか
- monthly schedule / recurrence / one-off exception / revised notice / URL/QRが過剰な万能workflowなしで扱えるか
- raw image private storage / access / delete / backup semanticsが十分か
- raw削除後もconfirmed household data/historyを安全に訂正できるか

### K. One-user test — Final GO MEDIUM-3

確認:

- fake auth userを作らない判断は妥当か
- production domain state machineを再利用できるか
- `execution_context=test_simulation`がserver-sideに強制されるか
- operator-facing `🧪 synthetic test delivery`は可能か
- synthetic deliveryがproduction user_notifications/outbox/consentと混ざらないか
- Google writeがhard blockされるか
- test analyticsがdefault excludedか
- real spouse onboarding時にsimulated agreementが昇格しないか
- side-effect guardがapplication if文だけでなくDB/adapter boundaryでも担保されるか

### L. Security / RLS / privacy

CURRENT v6 security modelと照合してください。

- browser direct business write禁止を維持しているか
- private schema/browser境界を維持しているか
- new tablesのhousehold isolation/FK/RLSが設計可能か
- simulated actorをreal household membershipに混ぜないか
- signed image URL/access controlが安全か
- logs/outbox/auditにraw source/private text/secretsが漏れないか

### M. Work packages / rollout

`07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`をレビューしてください。

- package順序はdependency的に妥当か
- giant-bang releaseになっていないか
- feature gateの粒度が適切か
- old/new writesが同時にtruthを持つ危険がないか
- production reconciliation/audit gatesが十分か
- real spouse onboarding前にone-user testを安全に行えるか
- review checkpointsが多すぎ/少なすぎないか

==================================================
4. CURRENT IMPLEMENTATION LEVERAGE REVIEW
==================================================

CURRENT `main`をfresh readし、以下について具体的に:

1. **そのまま再利用**
2. **拡張して再利用**
3. **意味が衝突するため再設計**
4. **新規領域**

へ分類してください。

最低限:

- household/auth/RLS
- task definitions/instances/subtasks
- recurrence rules/materialization
- task_events/history
- requests/Requests PWA
- handovers/shares
- routine_checkin_sessions
- Today/PendingAction
- LINE webhook/process-line-inbox
- mutation_receipts
- notification outbox/quota/retry
- Google OAuth/watch/sync/cache/projection/write
- PWA routing/deep links
- image intake
- test mode

「全部作り直し」または「既存を全部そのまま使える」のどちらにも安易に寄せないでください。

==================================================
5. OVERENGINEERING / SIMPLIFICATION REVIEW
==================================================

この設計は状態爆発を避けるために分離を増やしています。その分、table/conceptが増えています。

特に:

- request + attempts + confirmations
- task participant
- reconciliation sessions/items
- family events
- external links
- change candidates
- field authority
- source document/extraction/facts
- test simulation context

について、**必要なtruth separation**か、単なるarchitecture ceremonyかを厳しく評価してください。

同じsafety/UXを保ちながらtable/state/workerを減らせるなら具体案を出してください。

ただし単純化のために:

- silent overwrite
- dual completion truth
- guessed performer
- simulated consent contamination
- third-party privacy漏れ

を再導入しないでください。

==================================================
6. THREE FINAL-GO MEDIUM CARRYOVERS
==================================================

Requirements Final GO時の3 MEDIUMについて、今回の詳細設計で**実装acceptanceまで十分閉じたか**必ず個別判定してください。

1. `大体やった` + carryover UX noise
2. duplicate-sensitive neutral completion notification
3. one-user synthetic delivery vs production delivery boundary

各項目を:

- `PASS`
- `PARTIAL`
- `FAIL`

で評価し、`PARTIAL/FAIL`なら何を直せばよいか明示してください。

==================================================
7. REQUIRED OUTPUT
==================================================

最初に結論を短く示してください。

各指摘を:

- `BLOCKER`
- `HIGH`
- `MEDIUM`
- `LOW`

で分類してください。

各指摘形式:

**問題**
→ **実際に起こる家庭内/システムシナリオ**
→ **なぜ問題か**
→ **推奨修正**

さらに必ず以下を出してください。

### 7.1 Truth ownership audit table

Concernごとに「current truth / history / derived / conflict risk」を表にしてください。

### 7.2 Contradiction matrix

Detailed design内、およびRequirements/v6/current implementationとの緊張を列挙してください。

### 7.3 Migration safety table

主要existing truth → new truthについて:

- backfill
- compatibility
- cutover
- rollback/feature-off
- destructive risk

を評価してください。

### 7.4 CURRENT implementation leverage table

`reuse / extend / redesign / new` を具体的ファイル/table/function根拠付きで示してください。

### 7.5 Missing scenario list

実装前に本当に閉じる必要がある高影響scenarioだけを重要順に挙げてください。念のための無限列挙は禁止です。

### 7.6 Simplification opportunities

state/table/worker/notificationを減らせる案を、安全性を落とさず提案してください。

### 7.7 Data-model pressure points

特に壊れやすい境界を指摘してください。

### 7.8 Final-GO MEDIUM closure

Section 6の3項目をPASS/PARTIAL/FAILで再掲してください。

### 7.9 Final verdict

最後に必ず:

- `GO`
- `GO WITH CONDITIONS`
- `NO-GO`

のいずれかで、**この詳細設計をimplementation planning / implementation phaseへ進めてよいか**判定してください。

`BLOCKER`または`HIGH`が1件でも残るなら `GO` にしないでください。

`MEDIUM`のみの場合は、それがimplementation work-package acceptanceへ安全にcarry可能なら `GO` も認めます。

==================================================
8. REVIEW POSTURE
==================================================

この設計を肯定することが目的ではありません。

特に止めてほしいもの:

- dual truth
- state explosion
- migrationでのhistory破壊
- stale action resurrection
- concurrency last-write-wins
- notification fatigue
- duplicate-sensitive事故
- Google silent overwrite
- AI/source fact混同
- cross-child/cross-school誤結合
- third-party image privacy漏れ
- test data/consent contamination
- unnecessary abstraction/table proliferation

一方、SQL column type、Flex JSONの細部、OCR model名など、implementation時に安全に決められる事項まで「未決だからNO-GO」としないでください。

**実装者がこの設計だけを読んで、安全なmigration/command/UX設計へ着手できるか**を基準に独立評価してください。
