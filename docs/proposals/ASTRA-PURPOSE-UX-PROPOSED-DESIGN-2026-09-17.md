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
