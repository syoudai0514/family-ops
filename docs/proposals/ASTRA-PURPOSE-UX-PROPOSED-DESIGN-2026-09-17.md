# ASTRA → Sol PROPOSED detailed design
Status: **PROPOSED / NOT CANONICAL / NO RELEASE AUTHORIZATION**
Date: 2026-09-17
Reviewed source: `900313187c2460901f91d8aea66051e57729b50b`
Review: [独立レビュー](../reviews/ASTRA-PURPOSE-UX-REVIEW-2026-09-17.md)
Branch: `review/astra-purpose-ux-20260917`

## 0. Purpose → Requirements → UX → implementation
目的は家族の記憶・調整・確認の負担を減らすこと。機能数、AI利用回数、詳細入力率を成果にしない。通常日は少ない入力で閉じ、例外がある日だけ必要な判断を見せる。
本書は実装提案であり、merged canonicalを上書きしない。PF-01〜04およびPF-07は現行要件への適合改善。PF-05/06はPO-01/02未承認のため実装対象外。Solは承認済み設計との差分をcanonical detailed designに同じ変更単位で反映するが、未承認提案を転記して正本化してはいけない。

## 1. 家族が使う画面の着地点
- 朝: Today/LINEで例外と自分の作業を見る。コドモン送信行には締切と残る入力・担当が分かる。食事や体調本文はコドモンにだけ入力する。
- 思いついた時: 「＋追加」→即入力。「牛乳がなくなりそう。水曜のお迎えお願い」→候補と送信正文を一画面で確認→一度だけ確定。
- お願い: 相手、作業、日付/時刻、相手に見せる文面を確認する。生の愚痴や考え途中の原文は自動で相手に送らない。
- 通信不調: 保存できたか不明ならその事実を表示し、同じ操作を確認する。新規依頼をもう一通送って様子を見る必要をなくす。
- 夜: 「全部やった」「大体やった」「個別」は現行どおり。PF-06をPOが承認した場合だけCodmon最終送信を一般groupから除く。
- 相談: PF-05承認後だけPWAにも限定的な相談返答を出す。未承認ならLINEの既存相談導線を維持し、PWA汎用チャットは作らない。

## 2. 共通不変条件
1. 一つのshared canonical domain、既存command、RLS/ActorRef/contextを再利用。別Todo DB、別AI parser、別Request状態を作らない。
2. Request合意前は担当維持。受理後はlinked task。変更scopeとmaterial effectsを見せ、protected agreements/claim/actualを保護。
3. 重要な送信は人の確認内容とpayloadが一致。モデル出力、本文中の「送って」、候補選択だけを送信承認にしない。
4. 保存/通知の不確実性を成功や未送信に変換しない。operation IDは再試行で維持、入力変更は新しい操作として明示。
5. quota 200、reply-first、既存notification preferences・dedup・expiryを維持。PWA成功を同じ人のLINEへ返さない。
6. Codmon provider操作なし。家族の入力完了/送信完了申告だけ。AIはreadinessや担当・provider成功を推定しない。
7. UIの入力内容、元画面、scrollは保持。既存PWA recoveryを削除せず、部分更新でshellを再mountしない。
8. 本書によるproduction mutation/deploy/F2/main mergeは認めない。

## 3. 実装単位と依存
| Work package | 内容 | 分類 | DB migration |
|---|---|---|---|
| S0 | CURRENT/authority再確認、metadata driftのみ整理 | conforming docs | なし |
| S1 | PF-07 semantic parity + PF-02 immutable command preview + PF-01 input-first/単一確認 | conforming | assignment proposal CAS追加のfunction migration。table追加なし |
| S2 | PF-04 bounded API + stable attempt/recovery | conforming | 原則なし。既存idempotency欠落が実証されたendpointだけ追加migration |
| S3 | PF-03 Codmon readinessの共通読取とinline UI | conforming | additive function/projection migration |
| S4 | PO-01承認後PF-05 PWA相談返答 | REQUIREMENT CHANGE | なし |
| S5 | PO-02承認後PF-06 Codmon最終送信bulk除外 | REQUIREMENT CHANGE | additive command/read projection migration |

S1のconfirmed commandをS2のretry envelopeとして再利用。S3はS1/S2から独立するがS2のmutation結果不明UIを使う。S4/S5の判断待ちでS1〜3を止めない。提案を実装しないことを未完了bugとして数えない。

## 4. 変更対象の方針
既存concierge/router/command/DailyBriefの範囲で完結させる。専用command-center、チャット履歴DB、generic dependency engine、通知再設計、大規模refactorは作らない。
不要候補: QuickAddの最初の10選択肢modal、Results→Confirmの重複確認。削除は互換routeと手動入口を置換した後。既存業務機能・LINE必須経路は削除しない。
以下は実装用の提案契約。新規module名は提案、既存path/symbolはreviewed HEADで確認済み。

## 5. S1 / PF-07: 同じ入力を同じcommandへ接続する

### 5.1 Shared resolution boundary
既存 `decomposeLineConversationCandidates` は変更せずsemantic interpretationの入口として再利用。新規候補 `supabase/functions/_shared/resolveHouseholdCandidate.ts` に「候補＋認証済みhousehold context→resolved action」を置く。PWA proposal、LINE単一入力、LINE multi-intent pending生成から呼ぶ。LINE単一pickupの既存検索ロジックを小さく抽出し、別の推定器は作らない。
入力は `candidate`, `actorId`, `householdId`, `localDate`。household/actorはrequest bodyやAIから信頼せず、既存認証で導出。productionはtest_context_id nullで検索する。

Resolved actionのdiscriminator（候補kindの見た目と分離）:
```ts
type CandidateAction =
 | { type: 'task_create'; subtasks: {title:string; required:boolean; sort_order:number}[];
     calendarVisibility:'hidden'|'special'; context:string|null }
 | { type: 'request_create'; recipientUserId:string|null }
 | { type: 'assignment_change_request'; taskId:string; taskRevision:number;
     recipientUserId:string; scope:'once'|'this_week'; scheduledDate:string;
     dueAt:string|null; currentAssigneeId:string|null; linkedImpact: Impact[] }
 | { type: 'shopping_add' }
 | { type: 'handover_create' }
 | { type: 'actual_record' }
 | { type: 'needs_clarification'; field:string; question:string };
```
`Impact` は既存LINE受取確認が表示するmaterial dependent taskのcode/title/current/new owner。scope境界を人に見せるためのread-only snapshotで、AI生成を真実にしない。

### 5.2 Assignment解決規則
1. whole-inputのno-mutation/相談/訂正guardを先に適用。mixed inputは明示family-actionのsource spanだけ解決。
2. pickup変更cueは既存 `isPickupAssignmentChangeText` と `resolveJapanesePickupDate` を再利用。候補dateのユーザー修正は明示値として優先し、revision再取得。
3. household/date/definition code pickup/active occurrence/real contextを絞る。対象が一意で、依頼者が現在担当、相手が一意ならassignment_change_request。相手が既に担当なら「現在は相手の担当です」＋read-only表示で重複依頼を作らない。
4. 0件/複数件/recipient不明/日付不明は当該候補だけclarification。pickup変更cueがあるのにlight requestへ黙ってfallbackしない。利用者が明示的に「新しいお願い」と選んだ場合のみ別actionに再解決・再確認。
5. onceが既定。「今週だけ」は既存this_week契約を使用し対象日一覧をpreview。期間や曜日ルール変更をAIが作らない。対応していない期間は既存管理先へdraft付きで誘導し、勝手にonceに短縮しない。
6. dropoffその他の既存task指定も同じresolved-action型を使うが、認識範囲を正規表現追加だけで拡張しない。明示task ID等を持つ既存導線からの実行はそのまま維持。
7. candidate編集後はtarget lookup/duplicate evidenceを再検証。相手/対象date変化後に旧taskIdを使わない。

### 5.3 Mutation接続・concurrency
PWAは既存 `create-assignment-change-request` にtask_id/recipient_user_id/scope/shared_message/operation_idを渡す。LINE multi-intentのaction_typeに既存 `assignment_change_request` を追加し、pending確認dispatcherから同じDB commandへ接続する。
新規optional `expected_task_revision` をEdgeに追加。指定時は新しい `server_tx_create_assignment_change_request_v2`（名前は衝突確認）で処理:
- actor/household/context検証、operation receipt/hashによるreplay判定を先に行う。
- task rowをlockしexpected revision、date/scope、current ownerを再確認。違えば409 `ASSIGNMENT_PROPOSAL_STALE`、候補再表示。新規light requestに切り替えない。
- 既存canonical assignment creationへ委譲し、同一transactionでreceiptを保存。既存関数が既にreceiptを持つ場合、wrapperと二重claimせず一箇所に統合する。
- expected revisionなしの旧LINE等callerは既存contractで互換維持。本S1対象adapterは必ずrevisionを送る。
- Request作成だけではtask担当/role-derived家事は変えない。受理時は現行のattempt/terms revision、最終確認、dependent reassignmentを再利用。
table追加不要、function/Edge/type/testsのadditive migration。既存migrationを書き換えない。

### 5.4 Task候補の落とさない項目
`RawLineIntent` と `ConciergeCandidate` にsubtasks/context/calendarVisibilityを保持。準備物は独立taskに水増しせず、既存create-taskのsubtasksへ順序付きで渡す。itemsあり→completion_mode=subtasks、なし→whole。任意/必須はparserに明示根拠がある値、未指定は既存required既定を踏襲。
calendarVisibilityはhiddenへ強制せず、人がpreviewで確認した値を使用。specialならGoogle連携/表示に影響する旨を明記し、別Family Eventを同時に勝手に追加しない。contextは候補previewに保持し、現行create-taskにcontext保存fieldがないため、予定時刻等の必要なcontextは確認済みtask titleへ「病院の準備（11:00受診）」のように含める。raw全体をtitleに詰めず、既存title上限を守る。上限超過は編集を要求して黙って切り捨てない。
曖昧なvisibility/時刻をモデルから追加しない。AIが解析できない予定は既存イベント作成への明示遷移と原文保持、誤ったToDo確定は禁止。

### 5.5 Files / tests / evidence
既存: `supabase/functions/propose-concierge-candidates/index.ts`, `process-line-inbox/{index,lineMultiIntent,lineIntent}.ts`, `create-assignment-change-request/index.ts`, `create-task/index.ts`; PWA `conciergeFlow.ts` / `conciergeCommit.ts`。
新規: resolverとunit、assignment v2 function migration、SQL regression。
tests: raw単一/混在pickup、対象なし/複数/既に相手、stale occurrence、protected依存、曜日変更、相談だけ、no-send、準備物、context、明示visibility。正常単一LINEとPWAのconfirmed commandが同一。SQLでaccept前後の担当と通知数を確認。F2は2者の実LINE+PWA readbackが必要。

## 6. S1 / PF-02: 確認するものをそのまま送る

### 6.1 UI・state
draft → proposing → editing_review → ready_review → submitting → saved / partial / unknown / rejected。
previewとcommitを二つの画面で別構築しない。Resultsを一つのreview workspaceにし、Confirmのduplicate選択・結果・retryを組み込む。旧 `/concierge/confirm` routeは同じworkspaceを表示する互換adapterにし、旧stateは新型へ検証変換。必要なaction contractが無ければ「内容を確認し直してください」と候補へ戻し、自動登録しない。
タスクだけならCTA「2件を追加」。Request/Shareを含むなら「追加・相手に送る内容を確定」。選択checkboxは確定ではない。最終buttonを押すまでwriteしない。
相手が見る本文を原文より優先して表示。sourceTextは「自分の入力」として折り畳み、private originalを送信正文に流用しない。

### 6.2 Immutable confirmed envelope
新規 `confirmedCommand.ts` にpure builder:
```ts
type ConfirmedCommand = {
 candidateId:string; operationId:string; candidateRevision:number;
 endpoint:EdgeFunctionName; payload:Record<string, unknown>;
 preview:{title:string; recipientLabel?:string; sharedMessage?:string;
          dateLabel?:string; timeLabel?:string; scopeLabel?:string;
          impactLabels:string[]; subtaskLabels?:string[]};
};
```
builderはcandidate＋resolved actor/household/members＋duplicate decisionから **一度だけ** payloadを正規化し、previewはpayloadの値を整形する。commit dispatcherはcandidateを再解釈せずenvelope.payloadを送る。private original、AI confidence、operation ID、revisionは家族向けUIに露出しない。
request: recipientUserId明示、shared_title、shared_message、due_at、reply_due_at policy、scopeを確認。light requestは「了承までは予定担当は変わりません」、assignmentは既存対象・連動影響を表示。
share: 実際のshared_text、家庭全体/自分限定、validity等、現行adapterが送るものをそのままpreview。adapter非対応fieldを編集できるように見せない。
due時刻未指定の23:59正規化は「対象日中」と表示してpayloadと同じ意味にする。UIで勝手に09:00や20:00を補わない。自動reply_dueは「自動設定」と明記し、返事期限と作業期限を混ぜない。

### 6.3 編集・AI文案・送信の境界
- request候補でsharedMessageが空なら既存propose-ai-draftによる候補文案、または直接手入力を用意する。**sourceText fallbackは禁止**。ユーザーが原文を送りたい場合は「自分の入力を文面に使う」で明示転記しpreviewする。
- title/date/recipient/scope変更時にcandidateRevisionを増やし、envelopeを無効化。旧sharedMessageを勝手に新条件へ書き換えず、inline「条件を変更しました。送る文面も確認してください」を出す。文面編集または明示「この文面でよい」でreviewを有効化。単なるcheckboxの再選択では解除しない。
- AI書き換えは候補のみ。理由、頼みたい行動、期限を消さず、責めや嫌味を減らす。AI結果が遅れて返っても、その後の手編集revisionが違えば上書きしない。
- normalize/preview以降に未確認のAI処理を挟まない。宛先はmembersの現在状態で確認し、missing recipientをpartner fallbackで解決しない（resolverで確定済みなら可）。
- submit前の編集は未実行operation IDを保持可。submit開始後はenvelope immutable。unknown後の変更はS2の確認が済むまで別operationにしない。
- duplicate existing=no write、update=CAS、separate=明示createを維持。request等update未対応の選択肢はdisabled＋理由を示す。部分成功は成功candidate固定、失敗/unknownだけ同じenvelopeを再試行。

### 6.4 Tests / scope
`ConciergeConfirmPage.test.ts` のhelper-only testは残すが、それだけでPASSにしない。Reactでtitle/date/body編集→確認→mock network request bodyを比べるinteraction testを追加。`conciergeFlow.test.ts`、新規 `confirmedCommand.test.ts`、`conciergeCommit` testsを補強。
PF-02反例（火曜→水曜）と、原文に相手へ見せたくない一文があるケースは必須。明示確認なし原文送信0、preview本文=payload本文、編集後旧候補0、重複再送0。
DBは既存mutation schema、通知は既存Request/Share intentを利用。migrationはPF-07分以外不要。F2では送信前previewと相手の受取を同じscenario IDに結ぶ。

## 7. S1 / PF-01: 追加はまず入力できる
`QuickAdd` の通常clickは直接 `/concierge` へoriginPath/originScrollY付きでnavigate。`ConciergePage` の見出しは「追加・相談」ではなく未承認PF-05を先取りしない「追加」。lead「思いついたことを、そのまま書いてください」。CTA「内容を確認」。AIは裏で既存decompositionを利用するが「AIを選ぶ」工程は消す。
入力の下に「選んで入力」を折り畳み。既存quickAddOptionsのうちtask/event/request/shopping/handover/nursery/routine/preparation/actualを維持し、concierge自身は除く。手動taskは既存TaskFormModalを再利用、AI不調時にも使える。画像は現在PWA uploaderがあると装わず「LINEで送ったおたよりを確認」と既存nursery一覧へ。予定/買い物/実績の対応範囲を虚偽に広げない。
最初のtext入力を自然にfocus。ただしmobileの戻る復帰でキーボードを毎回強制表示しない。タップ領域44px、keyboard表示中CTA/戻るが使用可能。自動speech起動なし。
既存draft/origin保全を再利用しつつstorage keyをhousehold/userにscopeする（S2共通）。レビュー済み正文を原文へ潰して保存しない。
副作用/data/RPC変更なし。Q74/Q70とcurrent design04の入口・1画面確認を更新。tests: QuickAdd.test、新規QuickAdd.interaction、TodayConciergeBackState、NavigationStateManager。+から入力開始まで追加選択0、手動経路/戻る/scroll/編集保持/AI unavailableを確認。
PWAとLINEの画面数を揃えるためにLINEの必須確認を削らない。意味と副作用の一致を共通にする。

## 8. S3 / PF-03: Codmon readinessを送信taskに添える

### 8.1 共通projection
新しいtable/子タスク階層を作らず、既存5taskをそのまま使う。新規private read helper提案:
`private.fn_codmon_readiness_v1(p_household_id uuid,p_local_date date,p_test_context_id uuid default null) returns jsonb`。
stable / security invoker / search_path=''、PUBLIC/anon/authenticated execute revoke。認証済みDailyBrief経由のみ。production context null、testは既存test境界内から明示し、普通のPWAに任意context selectorを増やさない。
固定4codeをVALUESで列挙してLEFT JOIN。household/date/context一致。codeごとにexactly one rowがある場合のみ有効。欠落0件または重複>1件は `data_incomplete` とし、表示からreadyへ推定しない。

```ts
type CodmonReadiness = {
 local_date:string; deadline_at:string; submit_task_id:string|null;
 state:'not_applicable'|'data_incomplete'|'waiting_inputs'|'ready_to_submit'|'acknowledged';
 // acknowledgedは人の申告。provider確認済みではない。
 input_completed_count:number; required_input_count:4;
 inputs:{code:string; task_id:string|null; title:string;
   assignee_user_id:string|null; status:string|null;
   resolution:'present'|'missing'|'duplicate'}[];
 submit_assignee_user_id:string|null;
};
```
該当householdがCodmon未設定、または休日でtaskなし→not_applicable。平日で設定あり・生成不足→data_incomplete。入力全4completed、submit open→ready_to_submit。submit completed→acknowledged（入力の後日訂正があってもprovider送信履歴を自動巻戻ししない。訂正差分は表示）。skip/cancelは入力completedでない。submit cancelled/skippedは既存状態として表示し、ready CTAを出さない。
deadline_atは既存submit due_atを採用。未生成時のみ設定済みQ113の当該日09:15を補助表示。AIやbrowser timezoneで計算しない。

### 8.2 Reader / renderer接続
新migrationでCURRENT `private.fn_enrich_daily_brief_v1` の最新版に `codmon` propertyを追加。現行functionが後続migrationでreplaceされていないかSolが確認し、最後の定義を更新する。projectionは既存 `get_my_daily_brief` / server_read_daily_brief / LINE Todayを通る。同じcode list/helperをsubmit guardと09:00 reminderのready判定でも再利用し、「存在する未完了数=0」だけの判定を廃止。
既存guardの意味（遷移時4入力completed）を強化以外に変えない。read projection自体はmaterialize/completeを行わない。missing検出で本番rowを自動修復しない。
`useTodayData.DailyBriefPayload/TodaySnapshot` にoptional codmon、同じsnapshot単位で保持。既存own task listやpartner summaryを再分類せず、送信行へreadinessを添える。
`TaskChecklistItem` にoptional readonly `completionPrerequisite` prop、`TodayTaskItem` から対象IDにだけ渡す。コード名の日本語title判定は禁止。LINE rendererは送信taskの下に同じ残入力・担当を短く表示し、通常個別完了postbackを維持。

### 8.3 UX / state / error
| State | 表示 | 操作 |
|---|---|---|
| waiting_inputs | 「9:15まで／残り: 朝食（自分）、昨日の様子（相手）」 | 送信completedはdisabled。自分の該当taskへanchor、相手への自動催促なし |
| ready_to_submit | 「入力がそろっています。コドモンで送信してください」 | 「コドモンで送信した」=既存complete-task。tapでprovider送信はしない |
| data_incomplete | 「入力状況を確認できません。更新して確認してください」 | 再読込。送信成功を推定しない |
| acknowledged | 「コドモンで送信したと記録済み」 | 通常履歴/訂正へ。外部送信済みを自動確認したと表現しない |
| stale/offline | 「最後に確認した入力状況」 | readiness依存の新規完了は再取得を先行。DB guardは常に最終防壁 |

通常taskとして表示し、新しい全画面カードやKPI rowは作らない。PF-06未承認時はbulk適用を変えず、bulk失敗時にも残入力の説明を出す。
readinessがtrueでも他端末訂正で完了を拒否されたら409を受けて同一scopeをrefresh。二重clickは既存operation/terminal保護。AIはこの機能に関与しない。
通知: 09:00、adult/date一回、09:15 business expiry、quota/preference/fallbackを維持。ready文面もhelper結果に従う。追加push/高頻度催促なし。

### 8.4 Tests / rollout / canonical更新
SQL: `tests/sql/92_codmon_daily_submission.sql` にreadinessの0–4完了/欠落/別household/別日/test-context/休日/未設定/submit後訂正を追加。新SQLではduplicated fixtureも分離する。
PWA: `useTodayData.test.tsx`, `TaskChecklistItem.test.tsx`, `Today.states.interaction.test.tsx`。LINE: `lineTodayUx.test.ts` とSQL renderer test。DB guardをUIで代替しない。
backward compatibility: old clientはextra JSON keyを無視、新clientがkey欠落なら既存task表示＋「入力状況は完了時に確認」とし新しいready主張をしない。DB projection/guardを先にstaging、次にrenderer/frontend。同じreleaseでcanonical design12/04とtest evidenceを更新。Requirements Q113の意味は変更なし。F2は平日5task/担当/残項目/4入力gate/09:00/09:15/2端末反映を新HEADで再取得。

## 9. S2 / PF-04: bounded waitと結果不明の回復

### 9.1 共通clientの期限
既存 `apps/web/src/lib/apiClient.ts` にoptionsを追加する。既存2引数callerは互換。新規 `requestPolicy.ts` でendpointを `read` / `proposal` / `mutation` に静的分類し、命名prefixだけでmutation可否を推定しない。
- auth getSession: 12秒。
- read request: auth完了後12秒。
- ordinary mutation: auth完了後30秒。
- AI proposal: auth完了後45秒。
この値は実装上限であり、新しい家庭業務期限ではない。unit testではclock injection/偽timerを使う。
fetchにAbortController.signalを渡し、**response body readまで**同一deadlineでPromise.race。cleanupでtimer解除、late responseはUI stateを上書きしない。auth deadline後に遅れてgetSessionが返ってもfetchを開始しないチェックが必要。
AbortはDB transactionやLINE送信の取り消しを保証しない。dispatch開始後のnetwork/timeout/5xxは保守的に `outcome='unknown'`。fetch前の認証・明示offline・payload validation失敗は `not_sent`。確定的な4xx業務エラーは `rejected`、409 revision conflictは再確認へ。2xx malformed JSONもmutationでは成功表示せずunknown。
FamilyOpsApiErrorを拡張するかsubclassで `outcome` を持たせる。UNKNOWN/NETWORK_ERRORだけで呼び出し元が未送信と推測しない。
callEdgeFunctionに無条件自動retryは実装しない。service-role credentialや生JWTはjournal/consoleへ一切保存しない。

### 9.2 CommandAttempt（small frontend helper）
新規 `apps/web/src/lib/commandAttempt.ts` と `useCommandAttempt.ts` を置く。これはoffline queueではなく、利用者が既に明示確定した**一つの操作**の結果を確かめる仕組み。
```ts
type Attempt = {
 version:1; userId:string; householdId:string;
 operationId:string; endpoint:EdgeFunctionName;
 payload:Readonly<Record<string,unknown>>;
 state:'prepared'|'sending'|'unknown'|'succeeded'|'rejected';
 createdAt:string; // UI上の実績日には使わない
 result?:unknown;
};
```
- final confirmationでpreparedを作る。送信開始前にpersistし、同じ対象buttonのdouble clickをref guardで止める。
- retryは保存したendpoint/payload/operation_idをそのまま使用。再解析・今日の日付の再計算・新UUID発行は禁止。
- successを受けてdomain readbackをrefresh。receiptで成功と分かっているのに後続pending-action cleanupが失敗した場合、「送信済み、画面の整理を再試行」と分離し、新規send-requestを再発行しない。
- unknownは「送信結果を確認できません。もう一度確認しても二重には送られません」＋「結果を確認」。この文言はreceiptが保証されたendpointにだけ使う。
- unknown中はそのcommandの宛先/本文編集を止める。navは使える。相手に「送信失敗」と通知しない。
- retryで同じ操作の保存結果が返ればsucceeded。同じoperation IDで異なるpayloadを許容しない（backend receipt hashも検証）。
- 409競合は古い操作を再解釈して実行しない。最新状態を表示し、利用者が明示的に確定し直して初めて新しいoperation IDを発行。
- retry保証がない既存endpointは明示的なreadback経路のみ。「同じIDで二重にならない」というUIを出さない。強引にbodyへoperation_idを付けてもserver側receiptは増えない。

### 9.3 最初に必ず適用するconsumer
| Consumer | 保持する操作単位 | outcome unknown時 |
|---|---|---|
| conciergeCommit / review workspace | candidate別confirmed envelope | 成功candidate固定、unknownだけ同じIDで確認 |
| Requests.SendRequestForm | sendRequestまたはconfirmRequestDraftの確定payload | 同じID。pendingAction cleanupは別段階 |
| TaskChecklistItem / Todayのaccept・assignment actions | 対象task/attempt/revision/actionごとのpayload | canonical readback＋receipt replay。再renderでnewOperationIdを作り直さない |
| CheckinPage | group/session/eligible IDs/response/target date | 同じgroup操作をreplay。現在の残件へ対象を変えない |
| Shopping / AnyoneOwnerPage | item/revision/action | claimの競合は表示。購入済みを新しい買い物実績にしない |
| Handovers | confirmed shared_text/validity/action | 二重共有を作らない |
| NurseryReviewPage | intake/revision/選択item/value | current intake状態を再読込。confirmedなら成功、revision conflictなら再確認 |
| TaskFormModal | 確定済みcreate/edit payload | 作成済みを新規として作り直さない |

shared clientのbounded waitは全callerに効く。**上表のconsumerを未対応のままtimeoutだけ導入してmerge-readyにしない。** 既存endpointでrevision-based idempotencyのみの場合はauthoritative readbackに従う。
`get-routine-session` 等のreadは12秒timeoutで再読込可。取得中に古い成功dataがある場合はstaleとして保持、最初の失敗を空状態にしない。Todayの既存requestSequenceを他のread helperにも必要な範囲で再利用し、古い応答で画面を戻さない。

### 9.4 保存とprivacy / refresh
prepared/unknown envelopeはsessionStorageでuserId/householdId/versionを含むkeyに保存。既存のglobal concierge-draft keyもscope移行し、旧unscoped本文を別userへ自動移行しない。既存session内で所有者を証明できない旧値は破棄するか明示確認（表示自体が漏洩になるuser切替後は破棄）。
保存内容は送信承認済みpayloadとoperation IDだけ。API keys、JWT、生のprivate raw_input、画像binary/provider sourceは保存しない。raw_input_idは参照だけ。
success/rejectedで不要payloadを削除。logout/user/household切替はアクセス遮断して他者に表示せず、journalを消去する。24時間をUI再開期限とし、期限後は「履歴で結果を確認」にし自動replay/新規再送をしない。server receipt retentionをfresh-readして、replay上限をそれ以下にする（短い場合は短い方を採用）。
storage unavailable: 現在tabのmemoryで同じattemptを維持し、結果不明中のmanual reloadには「入力/結果確認をこの画面で続ける」案内。秘密をURLへ退避しない。
`refreshCurrentPwa` / PullToRefresh / SW activationで画面を再作成する前に、prepared/unknownと編集draftの保存を同期的に済ませる。既存workerの更新契約は維持。新しい強制reloadループやnavigation全体のロックは禁止。
offlineでの新規確定はdispatchせず入力保持。オンライン復帰で自動送信しない。ユーザーが確定/結果確認を押す。

### 9.5 Data / Edge / tests / rollback
原則DB table/schema追加なし。CURRENTのmutation_receipts/canonical operation receipt、idempotency/hash/CASを再利用。各上表endpointのCURRENT writerを確認してreceipt/readback保証を表に残す。保証欠落を実証したものだけ小さなDB function migrationを追加し、全domainの書き換えはしない。server outcomeを照会するためのpublic raw receipt table公開は不要。
unit: `apiClient.test.ts` にauth/fetch/body永久pending・deadline後late resolve・abort・認証切替・malformed 2xx・typed 4xx。
interaction: 「server commit成功→responseのみ消失→結果確認→1 Request/1 notification」、部分成功、checkin対象変化、receipt期限、別userが同じtab、storage例外、refresh、back。
SQL/Edge: operation ID＋hash同一のreplay、ID同一でpayload違い拒否、actor/household越境、accepted request重複task生成0。最新sourceの既存testsへ追加する。
Physical F2: Android/iPhoneのbackground→復帰、低速/通信切替、更新button/pull refresh、navigation、フォーム途中と送信中に分けて確認。fake timer unitのみで実機PASSにしない。
rollbackは旧clientへ戻してもcanonical receiptを消さない。client不具合はforward fixを優先し、unknown stateから新しいUUID送信を復活させるrollbackは禁止。

## 10. S4 / PF-05: PROPOSED PWA相談（PO-01なしで実装しない）
**承認する具体的変更:** Q74/§16に「PWA万能入力でも家族への伝え方・限定的な家庭相談に短い回答を返す」を追加。LINEの§28.3安全境界を両channelへ明示拡張。汎用assistant、長期memory、無料枠変更は含まない。
desired flow: 入力→same safety classifier→相談返答。返答を見ただけでRequestは作られない。「この文案をお願いとして確認」を押すとS1のcandidate reviewへ進み、相手/日付/bodyを確認して初めて送る。
API: `propose-concierge-candidates` のJSONにoptional `assistant_reply:string|null` / `disposition:'read_only'|'assistant'|'clarification'|'candidates'` を追加。既存keysは残す。会話分類は `lineNonMutationDisposition` / source-span guards、文案は `buildAssistantConversationReply` を共用。モデルプロンプトをPWA用に複製しない。
質問のtoday/tomorrow/weekはcanonical reader結果か対象date付き既存画面に接続し、「業務オブジェクトは作りません」だけで終えない。日時をLLMの記憶から回答しない。
mixed inputはassistant_reply＋明示action candidatesを同じ結果workspaceへ表示。相談中の家族名・「よさそうなら」・no-sendを送信承認に変換しない。短い2–4turn correctionは現在tabのexplicit stateを使い、旧draftをsupersededにする。永続的chat historyの追加は別PO判断とする。
AI timeout/unavailableは既存安全fallback。返答なしを創作して埋めない。0candidate相談を「入力失敗」と表示しない。AIは既存環境model設定/無料枠を使用し新課金なし。通知0、business mutation0、conversation textをfamily-visible recordへ保存しない。
files: proposal Edge、lineAssistantConversation/shared classifier、conciergeFlow/ResultsPage。migrationなし。
tests: existing `lineAssistantConversation.test.ts`, `lineAddresseeQualityCorpus.test.ts`, `lineConversationContextQuality.test.ts` をchannel adapter両方へ適用。相談/禁止/明示依頼/混在/訂正/逆訂正/捏造送信claims。F2はPWA相談→未送信の確認→明示送信の2者確認。PO未承認ならこの節だけDEFERRED。

## 11. S5 / PF-06: PROPOSED Codmon送信の独立申告（PO-02なしで実装しない）
**承認する具体的変更:** Q59/Q64のeligible-setに「Codmon最終送信を除外」の例外、Q113に「4入力後、外部で実際に送信してから専用1tap申告」を追記。§19.18 / design03/04/12も同時更新。4入力は現行groupに残る。
state: 4 input todo/completed → readiness ready → 人がCodmonで送信 → 人が専用buttonを押す → submit completed。ready/open/link clickではsubmit completedにしない。
新table、新generic dependency model、new consent modal不要。特定code `codmon_submit` のみ、private shared eligibility predicateでbulkから除外。正本taskをtask_subtaskへ変換しない。
変更対象:
- `private.fn_command_reconcile_task_group_v1` とCURRENTのroutine bulk adapter（`server_tx_complete_routine_session` 等、最終定義を検索）。
- `server_tx_get_routine_session` のeligible IDs/labels/count、LINE `lineMustComplete.ts` / `routineItemFlow.ts` のbulk対象表示、PWA CheckinPage。
- 個別 `complete-task` / LINE single-item完了は既存triggerを通して許可。
- `include_in_routine_line` をfalseにして送信taskを見えなくする修正は不可。表示対象とbulk対象は分離。
- old clientがsubmit IDをbulkに含めてもserverはscope全件検証後にsubmitだけ除外し、resultに `excluded_task_ids` と `exclusion_reason='explicit_external_submission_ack'` を返す。一般のforeign IDsや他人のtaskを無視して成功扱いする仕様は入れない。
- 手動でsubmitを完了済みの履歴は変更しない。過去bulkによる完了も自動取消しない。
- bulk結果は「朝の入力を記録しました。コドモンの送信確認が残っています」。既存summary/LINE rendererも残りsubmitを表示。exclude-onlyのbulkはbusiness no-opとして理由を返し、全部完了と表示しない。
- mostly_doneは従来どおりgroup evidenceのみ。undoは今回実際に変更したinput IDsだけで、独立した送信完了を巻戻さない。
migration: additive helper/command/readers/renderer replacement。新migrationをCLIで作り、既存Q113 migrationを編集しない。既存table dataのbackfill不要。
concurrency: group eligible IDsをserverで解決・lockする既存順序を保ち、submit/input同時操作は既存guardで再検証。submit ready readは助言、書込の真実はDB。409後の自動retryで人の送信申告を作らない。
tests: 4入力うち自分分bulk成功、submit未完了のまま、残り相手のinputでDB guard、4完了後1tap submit、LINE/PWA一致、old client bulk含有、mostly_done/undo、別日/context、同時個別入力。
rollout: reader/commandを同時DB migration→Edge/renderer→PWA。旧clientでも誤完了しないserver guardが先。PO未承認ならこの変更は未実装のまま現行bulkを維持する。

## 12. File / migration / test mapping
| Finding | 主な修正先（apps/web/src省略） | backend | 検証追加 |
|---|---|---|---|
| PF-01 | features/tasks/QuickAdd、features/concierge/Page/Results、app/AppShell互換 | 既存proposal | QuickAdd interaction、BackState、mobile browser |
| PF-02 | conciergeFlow/Commit/Results/Confirm、新confirmedCommand | 既存request/share commands | DOM→payload一致、原文非漏洩、部分成功 |
| PF-03 | today/useTodayData、TodayTaskItem、TaskChecklistItem | readiness helper / DailyBrief / Codmon guard/reminder / LINE renderer | SQL92拡張、read-model parity、9:00/9:15 |
| PF-04 | lib/apiClient、commandAttempt、上表consumers、pwaFreshness/PullToRefresh連携 | 既存receipt、欠落実証時のみ修正 | client偽timer＋失われた応答＋SQL replay＋実機 |
| PF-05 | conciergeFlow/Results | proposal + shared conversation | LINE corpusのPWA parity、通知0 |
| PF-06 | checkin、TodayTaskItem | bulk eligibility/read/LINE adapter | bulk/single/undo/old client parity |
| PF-07 | conciergeFlow/Commit、confirmedCommand | shared resolver、assignment Edge/RPC v2、LINE multi-intent | raw input→DB、subtasks、protected dependent |

既存testsの文字列存在チェックだけを増やさない。domain truth、actual transported payload、ユーザーの入口から結果までをassertする。
詳細実装はCURRENT最終関数定義を使う。歴史migrationの同名関数をcopyして後続修正を消すことは禁止。

## 13. 必須実利用シナリオ（検証ID）
| ID | 入力/前提 | 期待する結果 |
|---|---|---|
| A01 | PWA+で「牛乳がない」 | 分類選択なし、1review、買い物追加、予定/Requestなし |
| A02 | 「火曜お迎えお願い」→水曜へ編集 | preview/確定本文/対象occurrence/dateが水曜、旧火曜文面で送れない |
| A03 | 「牛乳がない。金曜のお迎え代わって」 | shopping＋existing pickup変更、受理前は担当維持 |
| A04 | 「明日11時病院。10時出る。保険証と診察券準備」 | 必要なcontext/準備2項目が確認・登録後も残る。誤った予定を増殖しない |
| A05 | 送信DB成功、HTTP応答消失 | unknown、同じIDで照会兼retry、Request/通知とも1回 |
| A06 | タスク/買い物/園review中にauth/fetch/bodyが止まる | bounded error、入力とnav維持、誤成功/false emptyなし |
| A07 | 平日8:50、Codmon2/4、相手入力残り | 送信taskに残入力/担当、通常完了を先に押させない |
| A08 | 4/4→別端末訂正→送信完了を押す | DB guard再検証、拒否＋最新状態、provider成功の誤表示なし |
| A09 | 9:00再試行/1row欠落/休日 | dedup、欠落をreadyにしない、休日は通常通知なし |
| A10 | Request acceptとToday refreshが競合 | canonical担当/依存/attemptへ収束、旧snapshotで承認しない |
| A11 | 相手が先に買い物claim、完了後undo | 既存claim/actual unit維持、商品数を家事件数にしない |
| A12 | 園画像→子/園の曖昧さ→確認→元画像削除 | 既存人確認/出典/確定データ保持、入力時timeout回復 |
| A13 | PO-01承認時「送らず文案だけ」 | PWA返答、候補/通知なし、明示操作後だけreview |
| A14 | PO-02承認時「朝全部やった」 | inputのみ完了、submit残る、外部送信後1tap申告 |
| A15 | iPhone/Android sleep/resume、更新/pull、Back | 最新shell、nav・draft/attempt・scroll保持、別userに内容なし |

A01–A12/A15はconforming lane。A13/A14は承認時だけ実施。承認なしに「test skip＝製品欠陥」としない。
browserは少なくともmobile 393×852と小さい幅、keyboard/long text/多タスクで確認。これは実端末F2を代替しない。

## 14. Rollout / gates /資料更新
1. CURRENT fresh-read: main、branch/HEAD、PR、changed files、CI、canonical、runtime migration version（read-only可能時）。古いPRの記載だけでQ113適用済みと扱わない。
2. S0/S1/S2/S3は非本番branchで実装。fixture-onlyの許可環境でtest。real妻への通知やprovider mutationなし。
3. targeted tests→full CIのweb/db/Edge/Supabase/evidence jobs→失敗原因修正→再CI。文言変更でbroken snapshotだけ更新してrequirements違反を隠さない。
4. self-reviewで要求→設計→実装→tests→A01–A15を照合、gaps明記。全routine scopeを変える追加案はここで勝手に採用しない。
5. canonical docs: design04 input/recovery、design03 command/state、design12 Codmon、design06 retry/privacy/evidence、必要なdesign02 function contract、design10 LINE/PWA責務の意味を維持した注記。BaselineはPF-05/06承認時のみ新behavior追加。それ以外は古いstatus metadata訂正と既存意味のclarification。
6. implementation reportにfinding ID、files、migrations、tests、not tested、F2 required、rollout/rollbackを記載。proposalを実装後の別CURRENT正本にしない。実装内容は正本へ、proposalはdecision historyとして維持。
7. commit/push→PR→merge-readyで止める。今回Solへの指示もproduction/main merge/F2は別承認。承認後はDB/Edge/PWAのexact deployed versionsを合わせ、必要F2を新HEADで実施してからproduct GO。
8. additive migration rollbackはdata/receipts/agreementsを消さず、forward fix。新旧reader互換を保つ。feature-offでlegacy truthへ戻さない。

## 15. 完成度・残る判断
実装方式・UX・state・再利用・対象file・RPC/DB・通知・test・F2・rolloutは本書で指定。SolはCURRENT差分と実在する最新symbolを照合するが、目的/UXを再設計してはならない。
残る**製品判断はPO-01/PO-02だけ**。本番migration適用、実機/通知品質、成功したUIの実測は未確認であり、設計完成と製品PASSを混同しない。
