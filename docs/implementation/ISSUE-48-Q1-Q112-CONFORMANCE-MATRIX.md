# Issue #48 — Q1–Q112 requirements conformance matrix

## Final zero-base assessment

This file is the durable implementation handoff for PR #50. The assessment below was rebuilt from the literal Appendix A decisions in `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`; the historical shortened matrix was not used as acceptance authority.

| Field | Value |
| --- | --- |
| Canonical issue | #48 |
| Working branch | `impl/issue-48-ux-closeout` |
| PR | #50 |
| Source evidence cut | `2c82671606c72049baaa3b03aa859ff5244d9174` |
| Pre-document full CI | #613: Web GREEN / Edge GREEN / DB GREEN / real Supabase CLI GREEN |
| Assessment | **PASS 112 / GATED Qs 0 / GAP 0** |
| Safety boundary | No main merge, production mutation/deploy, real LINE send, Google provider mutation, or production Supabase mutation. |
| Final exact-head evidence | The matrix commit itself changes the head. The final exact head + exact-head CI are recorded in the PR body and Issue #48 after this file is committed and CI is rerun. |

### Verdict vocabulary
- `PASS`: the CURRENT implementation realizes the literal requirement and has source/test/use-scenario evidence.
- `GATED`: only for a canonical external/release gate that cannot be closed by source implementation.
- `GAP`: implementation/test gap. Final count must be zero.

### Cross-cutting evidence
- LINE/H6: `supabase/functions/process-line-inbox/`, `_shared/lineMessageBuilders*`, migrations `20260905000003`–`000008`, SQL 62–65.
- Event planning Q17: migration `20260905000009`, `EventPlanPage*`, SQL `66_q17_event_planning_confirmation.sql`.
- Nursery Q89–Q106: DD9 foundation + migrations `20260905000010`–`00018`, `00028`, `00029`; `NurseryReviewPage*`; SQL 66–72.
- Transport: migrations `20260905000020`, `00021`, `00023`, `00024`, `00030`, `00031`, `20260906000001`; SQL 70 + 74.
- Shopping Q107–Q109: canonical shopping claim lifecycle; SQL `71_shopping_anyone_claim_lifecycle.sql`.
- Google Q110–Q112: migrations `20260905000032`, `00033`; `GoogleEventReviewPage*`; SQL `73_google_human_confirmed_diff_review.sql`.
- Exact-source CI #613 also passed full DB migrations/RLS/RPC/idempotency/quota, Edge lint/typecheck/unit/auth matrix, Web lint/typecheck/test/build, real Supabase CLI stack, DD11 zero-leak audits, reconciliation audits, and true-parallel concurrency.

## Q1–Q112 literal conformance

| Q | Literal requirement | CURRENT implementation | Test evidence | Real-use scenario | Verdict |
| --- | --- | --- | --- | --- | --- |
| Q1 | システムは今日やることを能動的に構成して提示する。 | `Today.tsx` + `useTodayData.ts` daypart/priority/read-model composition | `Today.test.tsx`; `TodayEvening.test.tsx` | 朝/夜にTodayを開くと、確認事項から今日の自分作業まで現在時刻に合わせて並ぶ。 | PASS |
| Q2 | 軽いお願い / 担当変更 / 情報共有を別フローにする。 | `Requests.tsx` + request/attempt canonical commands (`respond-request`, `negotiate-request`) | Web Request tests + DB request/attempt SQL suite in CI #613 | 家庭でこの条件が発生したとき、軽いお願い / 担当変更 / 情報共有を別フローにする動作になることをUI/commandで確認。 | PASS |
| Q3 | 共有情報は有効期間を持てる。 | `Handovers.tsx` + `server_tx_create_handover_v2` validity/ack policy | handover Web/DB regression suite in CI #613 | 家庭でこの条件が発生したとき、共有情報は有効期間を持てる動作になることをUI/commandで確認。 | PASS |
| Q4 | LINEは固定入口+会話/Flex+自然文を目標。実装制約時も業務ロジックを分けない。 | `process-line-inbox` + shared LINE builders/pending-action canonical RPCs | `lineConversation.test.ts`; `lineMultiIntent.test.ts`; `lineMessageBuilders.test.ts`; SQL 62–65 | 妻がLINEで自然文を送り、内容確認・修正後にPWAでも同じcanonical状態を見られる。 | PASS |
| Q5 | 実績はその場入力と夜まとめの両方。 | `CheckinPage.tsx` / routine-session canonical reconciliation commands | check-in/routine Web tests + canonical reconciliation SQL/concurrency suite | 家庭でこの条件が発生したとき、実績はその場入力と夜まとめの両方動作になることをUI/commandで確認。 | PASS |
| Q6 | 通常は「全部自分でやった」、例外だけ入力。 | `CheckinPage.tsx` / routine-session canonical reconciliation commands | check-in/routine Web tests + canonical reconciliation SQL/concurrency suite | 家庭でこの条件が発生したとき、通常は「全部自分でやった」、例外だけ入力動作になることをUI/commandで確認。 | PASS |
| Q7 | 実績は完了した家庭運営作業。細粒度・調査だけは原則除外。 | `HistoryPage.tsx` + task events / `task_actual_participants` audit model | `HistoryPage.test.tsx` + audit/actual participant SQL tests | 家庭でこの条件が発生したとき、実績は完了した家庭運営作業。細粒度・調査だけは原則除外動作になることをUI/commandで確認。 | PASS |
| Q8 | 予定外作業は頻用shortcut+free text。 | `QuickAdd.tsx` / task form + canonical task adapters | `QuickAdd.test.ts` + task adapter SQL/Web tests | 家庭でこの条件が発生したとき、予定外作業は頻用shortcut+free text動作になることをUI/commandで確認。 | PASS |
| Q9 | お願いreminderはTodayに溶かし、期限リスク時のみ強める。個別override可。 | `Today.tsx` + `useTodayData.ts` daypart/priority/read-model composition | `Today.test.tsx`; `TodayEvening.test.tsx` | 家庭でこの条件が発生したとき、お願いreminderはTodayに溶かし、期限リスク時のみ強める。個別override可動作になることをUI/commandで確認。 | PASS |
| Q10 | 役割連動家事は日/期間override可能。 | planning/assignment UI + canonical rule/assignment commands and notification policy | planning/assignment Web + DB policy/regression tests | 家庭でこの条件が発生したとき、役割連動家事は日/期間override可能動作になることをUI/commandで確認。 | PASS |
| Q11 | 両方在宅でも自動共同担当にしない。 | planning/assignment UI + canonical rule/assignment commands and notification policy | planning/assignment Web + DB policy/regression tests | 家庭でこの条件が発生したとき、両方在宅でも自動共同担当にしない動作になることをUI/commandで確認。 | PASS |
| Q12 | 曜日ルールは有効期間を持つ。 | planning/assignment UI + canonical rule/assignment commands and notification policy | planning/assignment Web + DB policy/regression tests | 家庭でこの条件が発生したとき、曜日ルールは有効期間を持つ動作になることをUI/commandで確認。 | PASS |
| Q13 | 未来担当を見せ、他者が前倒し実施できる。 | `Today.tsx` + `useTodayData.ts` daypart/priority/read-model composition | `Today.test.tsx`; `TodayEvening.test.tsx` | 家庭でこの条件が発生したとき、未来担当を見せ、他者が前倒し実施できる動作になることをUI/commandで確認。 | PASS |
| Q14 | 前倒し可能という理由だけの単独reminderは送らない。 | notification/DailyBrief scheduling and delivery policy | notification/DailyBrief scheduler SQL/Edge tests | 家庭でこの条件が発生したとき、前倒し可能という理由だけの単独reminderは送らない動作になることをUI/commandで確認。 | PASS |
| Q15 | 相手の前倒し実施は、自分の負担が減るときだけ次回表示。 | `Today.tsx` + `useTodayData.ts` daypart/priority/read-model composition | `Today.test.tsx`; `TodayEvening.test.tsx` | 家庭でこの条件が発生したとき、相手の前倒し実施は、自分の負担が減るときだけ次回表示動作になることをUI/commandで確認。 | PASS |
| Q16 | 共有の確認要求は重要度に応じる。LINE既読は前提にしない。 | `Handovers.tsx` + `server_tx_create_handover_v2` validity/ack policy | handover Web/DB regression suite in CI #613 | 家庭でこの条件が発生したとき、共有の確認要求は重要度に応じる。LINE既読は前提にしない動作になることをUI/commandで確認。 | PASS |
| Q17 | イベントはtemplate+AI候補+人確認。 | `EventPlanPage.tsx` + event planning draft/confirm pipeline | `66_q17_event_planning_confirmation.sql`; `EventPlanPage.test.ts` | 七五三を追加し、template/AI候補を編集・選択して確認するまでEvent/ToDoは作られない。 | PASS |
| Q18 | イベント全体取りまとめ担当は置かない。 | `EventPlanPage.tsx` + event planning draft/confirm pipeline | `66_q17_event_planning_confirmation.sql`; `EventPlanPage.test.ts` | 家庭でこの条件が発生したとき、イベント全体取りまとめ担当は置かない動作になることをUI/commandで確認。 | PASS |
| Q19 | イベントLINEは節目/リスク時だけ。 | notification/DailyBrief scheduling and delivery policy | notification/DailyBrief scheduler SQL/Edge tests | 家庭でこの条件が発生したとき、イベントLINEは節目/リスク時だけ動作になることをUI/commandで確認。 | PASS |
| Q20 | 状況は最新を通常表示し履歴を別表示。 | `HistoryPage.tsx` + task events / `task_actual_participants` audit model | `HistoryPage.test.tsx` + audit/actual participant SQL tests | 家庭でこの条件が発生したとき、状況は最新を通常表示し履歴を別表示動作になることをUI/commandで確認。 | PASS |
| Q21 | 着手可能/目安/期限/reminderはすべて任意。 | `QuickAdd.tsx` / task form + canonical task adapters | `QuickAdd.test.ts` + task adapter SQL/Web tests | 家庭でこの条件が発生したとき、着手可能/目安/期限/reminderはすべて任意動作になることをUI/commandで確認。 | PASS |
| Q22 | `待ち` + 次回確認日を持つ。 | `TaskChecklistItem.tsx` + `set-task-waiting` + `shouldShowWaitingTask` | `Today.test.tsx` future-wait suppression/no-next-check + waiting adapter tests | 園の返事待ちを次回確認日なしでも待ちにでき、未来確認日のものは期限リスクがなければTodayに出続けない。 | PASS |
| Q23 | Todayは「まず確認→例外→共有→済み→今日やること」の階層。 | `Today.tsx` + `useTodayData.ts` daypart/priority/read-model composition | `Today.test.tsx`; `TodayEvening.test.tsx` | 家庭でこの条件が発生したとき、Todayは「まず確認→例外→共有→済み→今日やること」の階層動作になることをUI/commandで確認。 | PASS |
| Q24 | タスクは時間帯で大分類し、その中で必須/通常/余力。 | `Today.tsx` + `useTodayData.ts` daypart/priority/read-model composition | `Today.test.tsx`; `TodayEvening.test.tsx` | 家庭でこの条件が発生したとき、タスクは時間帯で大分類し、その中で必須/通常/余力動作になることをUI/commandで確認。 | PASS |
| Q25 | scheduled pushは朝+夜を中心、例外は随時。 | notification/DailyBrief scheduling and delivery policy | notification/DailyBrief scheduler SQL/Edge tests | 家庭でこの条件が発生したとき、scheduled pushは朝+夜を中心、例外は随時動作になることをUI/commandで確認。 | PASS |
| Q26 | 夜定時は20:30。 | notification/DailyBrief scheduling and delivery policy | notification/DailyBrief scheduler SQL/Edge tests | 家庭でこの条件が発生したとき、夜定時は20:30動作になることをUI/commandで確認。 | PASS |
| Q27 | 1つのLINEで双方を疑似体験するtest mode。 | `TestSimulation.tsx` + isolated synthetic LINE `test_delivery_outbox` commands | `TestSimulation.test.tsx`; DD11 zero-leak audits | 本人1人で🧪LINE会話の双方を操作しても、本物の配偶者/LINE/Google/analyticsへ副作用を出さない。 | PASS |
| Q28 | 実績分析は非push・奥に置く。 | `HistoryPage.tsx` + task events / `task_actual_participants` audit model | `HistoryPage.test.tsx` + audit/actual participant SQL tests | 家庭でこの条件が発生したとき、実績分析は非push・奥に置く動作になることをUI/commandで確認。 | PASS |
| Q29 | 実績訂正を許し、履歴を保持。 | `HistoryPage.tsx` + task events / `task_actual_participants` audit model | `HistoryPage.test.tsx` + audit/actual participant SQL tests | パパ+ママ実施済みの履歴を開き訂正しても、未変更のもう一方の実施者が消えない。 | PASS |
| Q30 | 担当調整期限超過はそのattemptを不成立+元担当維持。継続希望時も古いattemptは復活させず再提案へ。 | `Requests.tsx` + request/attempt canonical commands (`respond-request`, `negotiate-request`) | Web Request tests + DB request/attempt SQL suite in CI #613 | 家庭でこの条件が発生したとき、担当調整期限超過はそのattemptを不成立+元担当維持。継続希望時も古いattemptは復活させず再提案へ動作になることをUI/commandで確認。 | PASS |
| Q31 | 未完了時の扱いはタスク性質ごと。 | `CheckinPage.tsx` / routine-session canonical reconciliation commands | check-in/routine Web tests + canonical reconciliation SQL/concurrency suite | 家庭でこの条件が発生したとき、未完了時の扱いはタスク性質ごと動作になることをUI/commandで確認。 | PASS |
| Q32 | 1タスクに複数実施者を持てるが、通常UIを複雑にしない。 | `HistoryPage.tsx` + task events / `task_actual_participants` audit model | `HistoryPage.test.tsx` + audit/actual participant SQL tests | 家庭でこの条件が発生したとき、1タスクに複数実施者を持てるが、通常UIを複雑にしない動作になることをUI/commandで確認。 | PASS |
| Q33 | 買い物は商品数でなく行動1件を実績にする。 | `Shopping.tsx` + canonical shopping claim lifecycle | `71_shopping_anyone_claim_lifecycle.sql` + Shopping action tests | 家庭でこの条件が発生したとき、買い物は商品数でなく行動1件を実績にする動作になることをUI/commandで確認。 | PASS |
| Q34 | Googleは予定中心、ToDoは必要時のみ表示。 | `GoogleEventReviewPage.tsx` + Google cache/review/authority pipeline | `73_google_human_confirmed_diff_review.sql` + Google projection/isolation tests | 家庭でこの条件が発生したとき、Googleは予定中心、ToDoは必要時のみ表示動作になることをUI/commandで確認。 | PASS |
| Q35 | 自分の担当を主表示、相手は要約。 | `Today.tsx` + `useTodayData.ts` daypart/priority/read-model composition | `Today.test.tsx`; `TodayEvening.test.tsx` | 家庭でこの条件が発生したとき、自分の担当を主表示、相手は要約動作になることをUI/commandで確認。 | PASS |
| Q36 | 引き受けたお願いは通常ToDoに合流。合意まではRequest、了承後の実行状態はlinked ToDoを正とし依頼来歴を保持。 | `Requests.tsx` + request/attempt canonical commands (`respond-request`, `negotiate-request`) | Web Request tests + DB request/attempt SQL suite in CI #613 | 家庭でこの条件が発生したとき、引き受けたお願いは通常ToDoに合流。合意まではRequest、了承後の実行状態はlinked ToDoを正とし依頼来歴を保持動作になることをUI/commandで確認。 | PASS |
| Q37 | 対応必要な引き継ぎだけ確認要求。共有と自分ToDoの組合せを許容。 | `Handovers.tsx` + `server_tx_create_handover_v2` validity/ack policy | handover Web/DB regression suite in CI #613 | 家庭でこの条件が発生したとき、対応必要な引き継ぎだけ確認要求。共有と自分ToDoの組合せを許容動作になることをUI/commandで確認。 | PASS |
| Q38 | 共有は家庭全体がdefault、自分だけを例外にする。 | `Handovers.tsx` + `server_tx_create_handover_v2` validity/ack policy | handover Web/DB regression suite in CI #613 | 家庭でこの条件が発生したとき、共有は家庭全体がdefault、自分だけを例外にする動作になることをUI/commandで確認。 | PASS |
| Q39 | 新規共有/依頼を定時通知まで寝かせず、原則随時。定時は再整理。 | `process-line-inbox` + shared LINE builders/pending-action canonical RPCs | `lineConversation.test.ts`; `lineMultiIntent.test.ts`; `lineMessageBuilders.test.ts`; SQL 62–65 | 家庭でこの条件が発生したとき、新規共有/依頼を定時通知まで寝かせず、原則随時。定時は再整理動作になることをUI/commandで確認。 | PASS |
| Q40 | 相手実施を都度通知せず、次のまとめで状態として見せる。 | `Today.tsx` + `useTodayData.ts` daypart/priority/read-model composition | `Today.test.tsx`; `TodayEvening.test.tsx` | 家庭でこの条件が発生したとき、相手実施を都度通知せず、次のまとめで状態として見せる動作になることをUI/commandで確認。 | PASS |
| Q41 | `難しい` に表現統一。`コメント付きで難しい` は1通で最終通知。 | `Requests.tsx` + request/attempt canonical commands (`respond-request`, `negotiate-request`) | Web Request tests + DB request/attempt SQL suite in CI #613 | お願いに『コメント付きで難しい』を1回送ると、理由付きの最終回答として記録される。 | PASS |
| Q42 | 軽いお願いは難しいで終了、必須問題は担当未解決として残す。 | `Requests.tsx` + request/attempt canonical commands (`respond-request`, `negotiate-request`) | Web Request tests + DB request/attempt SQL suite in CI #613 | 家庭でこの条件が発生したとき、軽いお願いは難しいで終了、必須問題は担当未解決として残す動作になることをUI/commandで確認。 | PASS |
| Q43 | `確認してみる` は自分側調整、`相談する` は相手との条件相談。 | `Requests.tsx` + request/attempt canonical commands (`respond-request`, `negotiate-request`) | Web Request tests + DB request/attempt SQL suite in CI #613 | 『相談する』で条件を提案し、一方確認中は担当を変えず、双方同条件確認後だけ確定する。 | PASS |
| Q44 | 第一階層は `やる / 難しい / その他の返答`。 | `Requests.tsx` + request/attempt canonical commands (`respond-request`, `negotiate-request`) | Web Request tests + DB request/attempt SQL suite in CI #613 | 家庭でこの条件が発生したとき、第一階層は `やる / 難しい / その他の返答`動作になることをUI/commandで確認。 | PASS |
| Q45 | 依頼内容変更は上書きでなく変更提案。 | `Requests.tsx` + request/attempt canonical commands (`respond-request`, `negotiate-request`) | Web Request tests + DB request/attempt SQL suite in CI #613 | 家庭でこの条件が発生したとき、依頼内容変更は上書きでなく変更提案動作になることをUI/commandで確認。 | PASS |
| Q46 | 了承後の依頼取消は相手確認が必要。 | `Requests.tsx` + request/attempt canonical commands (`respond-request`, `negotiate-request`) | Web Request tests + DB request/attempt SQL suite in CI #613 | 家庭でこの条件が発生したとき、了承後の依頼取消は相手確認が必要動作になることをUI/commandで確認。 | PASS |
| Q47 | 返答期限と作業期限を分け、返答期限は自動提案。 | `Requests.tsx` + request/attempt canonical commands (`respond-request`, `negotiate-request`) | Web Request tests + DB request/attempt SQL suite in CI #613 | 家庭でこの条件が発生したとき、返答期限と作業期限を分け、返答期限は自動提案動作になることをUI/commandで確認。 | PASS |
| Q48 | 情報有効期限は関連ToDo完了と別。 | `Handovers.tsx` + `server_tx_create_handover_v2` validity/ack policy | handover Web/DB regression suite in CI #613 | 家庭でこの条件が発生したとき、情報有効期限は関連ToDo完了と別動作になることをUI/commandで確認。 | PASS |
| Q49 | 訂正情報は旧情報を履歴化して最新を有効化。 | `HistoryPage.tsx` + task events / `task_actual_participants` audit model | `HistoryPage.test.tsx` + audit/actual participant SQL tests | 家庭でこの条件が発生したとき、訂正情報は旧情報を履歴化して最新を有効化動作になることをUI/commandで確認。 | PASS |
| Q50 | ルール由来未来予定だけ再計算。個別合意は維持確認を双方へ。 | planning/assignment UI + canonical rule/assignment commands and notification policy | planning/assignment Web + DB policy/regression tests | 家庭でこの条件が発生したとき、ルール由来未来予定だけ再計算。個別合意は維持確認を双方へ動作になることをUI/commandで確認。 | PASS |
| Q51 | 個別合意見直しで不一致なら元合意を維持し担当調整中。 | `Requests.tsx` + request/attempt canonical commands (`respond-request`, `negotiate-request`) | Web Request tests + DB request/attempt SQL suite in CI #613 | 家庭でこの条件が発生したとき、個別合意見直しで不一致なら元合意を維持し担当調整中動作になることをUI/commandで確認。 | PASS |
| Q52 | 適用範囲はAI推定+確定前表示。 | planning/assignment UI + canonical rule/assignment commands and notification policy | planning/assignment Web + DB policy/regression tests | 家庭でこの条件が発生したとき、適用範囲はAI推定+確定前表示動作になることをUI/commandで確認。 | PASS |
| Q53 | `今回は不要` はその回のみ。継続なら見直し提案。 | `CheckinPage.tsx` / routine-session canonical reconciliation commands | check-in/routine Web tests + canonical reconciliation SQL/concurrency suite | 家庭でこの条件が発生したとき、`今回は不要` はその回のみ。継続なら見直し提案動作になることをUI/commandで確認。 | PASS |
| Q54 | 一部進捗はstatus/subitemsで、日常に専用buttonを増やさない。 | `CheckinPage.tsx` / routine-session canonical reconciliation commands | check-in/routine Web tests + canonical reconciliation SQL/concurrency suite | 家庭でこの条件が発生したとき、一部進捗はstatus/subitemsで、日常に専用buttonを増やさない動作になることをUI/commandで確認。 | PASS |
| Q55 | 明示的な「明日やる」等だけ再予定として扱う。 | `QuickAdd.tsx` / task form + canonical task adapters | `QuickAdd.test.ts` + task adapter SQL/Web tests | 家庭でこの条件が発生したとき、明示的な「明日やる」等だけ再予定として扱う動作になることをUI/commandで確認。 | PASS |
| Q56 | 標準所要時間は任意、実時間入力は要求しない。 | `QuickAdd.tsx` / task form + canonical task adapters | `QuickAdd.test.ts` + task adapter SQL/Web tests | 家庭でこの条件が発生したとき、標準所要時間は任意、実時間入力は要求しない動作になることをUI/commandで確認。 | PASS |
| Q57 | 重要度は自動推定し必要時だけ変更。 | `QuickAdd.tsx` / task form + canonical task adapters | `QuickAdd.test.ts` + task adapter SQL/Web tests | 家庭でこの条件が発生したとき、重要度は自動推定し必要時だけ変更動作になることをUI/commandで確認。 | PASS |
| Q58 | 複雑なタスク依存関係は保留。日常の一括実績groupを優先。 | No dependency-DAG product surface; daily meaningful group/reconciliation path retained per explicit deferral | Q58 source/schema audit + routine grouping/reconciliation tests | 日常の朝/夜groupをまとめて実績入力できる一方、複雑なDAG依存UIは持ち込まない。 | PASS |
| Q59 | 一括完了は即確定し、直後に例外修正/undo。 | `CheckinPage.tsx` / routine-session canonical reconciliation commands | check-in/routine Web tests + canonical reconciliation SQL/concurrency suite | 家庭でこの条件が発生したとき、一括完了は即確定し、直後に例外修正/undo動作になることをUI/commandで確認。 | PASS |
| Q60 | 自動group+custom groupを許容。Q60-1: 日常groupは表示箱、event等はproject container。親は実績件数にしない。Q60-2: 意味あるまとまりだけ一括実績を許可。 | `CheckinPage.tsx` / routine-session canonical reconciliation commands | check-in/routine Web tests + canonical reconciliation SQL/concurrency suite | 家庭でこの条件が発生したとき、自動group+custom groupを許容し、日常groupとevent containerを分け、意味あるまとまりだけ一括実績にする。 | PASS |
| Q61 | 一括完了に `余力があれば` は含めない。 | `CheckinPage.tsx` / routine-session canonical reconciliation commands | check-in/routine Web tests + canonical reconciliation SQL/concurrency suite | 家庭でこの条件が発生したとき、一括完了に `余力があれば` は含めない動作になることをUI/commandで確認。 | PASS |
| Q62 | 実績時刻はユーザー管理しない。登録時刻は監査用のみ。 | `HistoryPage.tsx` + task events / `task_actual_participants` audit model | `HistoryPage.test.tsx` + audit/actual participant SQL tests | 家庭でこの条件が発生したとき、実績時刻はユーザー管理しない。登録時刻は監査用のみ動作になることをUI/commandで確認。 | PASS |
| Q63 | 翌日入力でも元タスク対象日に実績を紐づける。 | `CheckinPage.tsx` / routine-session canonical reconciliation commands | check-in/routine Web tests + canonical reconciliation SQL/concurrency suite | 家庭でこの条件が発生したとき、翌日入力でも元タスク対象日に実績を紐づける動作になることをUI/commandで確認。 | PASS |
| Q64 | 未入力時は `全部やった / 大体やった / 個別で答える`。大体はgroup-level証跡で、子taskは完了/例外/不明のままcarryover ruleに従う。 | `CheckinPage.tsx` / routine-session canonical reconciliation commands | check-in/routine Web tests + canonical reconciliation SQL/concurrency suite | 夜に『大体やった』を選んでも子taskを全完了扱いせず、完了/例外/不明を保つ。 | PASS |
| Q65 | 個別回答はLINE/PWAを選べる。 | `process-line-inbox` + shared LINE builders/pending-action canonical RPCs | `lineConversation.test.ts`; `lineMultiIntent.test.ts`; `lineMessageBuilders.test.ts`; SQL 62–65 | 家庭でこの条件が発生したとき、個別回答はLINE/PWAを選べる動作になることをUI/commandで確認。 | PASS |
| Q66 | LINE個別入力は例外だけ答えるのを基本にし、1件ずつmodeも可。 | `process-line-inbox` + shared LINE builders/pending-action canonical RPCs | `lineConversation.test.ts`; `lineMultiIntent.test.ts`; `lineMessageBuilders.test.ts`; SQL 62–65 | 家庭でこの条件が発生したとき、LINE個別入力は例外だけ答えるのを基本にし、1件ずつmodeも可動作になることをUI/commandで確認。 | PASS |
| Q67 | 自分のタスクはLINEに全部書き、順番と強調で読みやすくする。 | `process-line-inbox` + shared LINE builders/pending-action canonical RPCs | `lineConversation.test.ts`; `lineMultiIntent.test.ts`; `lineMessageBuilders.test.ts`; SQL 62–65 | 家庭でこの条件が発生したとき、自分のタスクはLINEに全部書き、順番と強調で読みやすくする動作になることをUI/commandで確認。 | PASS |
| Q68 | 相手は要約、家庭運営に重要なものだけ具体表示。 | `Today.tsx` + `useTodayData.ts` daypart/priority/read-model composition | `Today.test.tsx`; `TodayEvening.test.tsx` | 家庭でこの条件が発生したとき、相手は要約、家庭運営に重要なものだけ具体表示動作になることをUI/commandで確認。 | PASS |
| Q69 | 担当未定で登録可能。期限接近で担当決定を強調。 | `QuickAdd.tsx` / task form + canonical task adapters | `QuickAdd.test.ts` + task adapter SQL/Web tests | 家庭でこの条件が発生したとき、担当未定で登録可能。期限接近で担当決定を強調動作になることをUI/commandで確認。 | PASS |
| Q70 | 1メッセージの複数意図を分解し、1画面でまとめて確認。 | `process-line-inbox` + shared LINE builders/pending-action canonical RPCs | `lineConversation.test.ts`; `lineMultiIntent.test.ts`; `lineMessageBuilders.test.ts`; SQL 62–65 | 1通に予定・買い物・お願い等が混ざっても候補を分けて1回の確認面に出す。 | PASS |
| Q71 | 曖昧な箇所だけ質問。 | `process-line-inbox` + shared LINE builders/pending-action canonical RPCs | `lineConversation.test.ts`; `lineMultiIntent.test.ts`; `lineMessageBuilders.test.ts`; SQL 62–65 | 自然文のうち不明な担当/日時だけを質問し、理解済み内容は聞き直さない。 | PASS |
| Q72 | 家庭用語を学習。ただしルール自動変更はしない。 | `process-line-inbox` + shared LINE builders/pending-action canonical RPCs | `lineConversation.test.ts`; `lineMultiIntent.test.ts`; `lineMessageBuilders.test.ts`; SQL 62–65 | 家庭固有語を解釈に使っても、曜日ルール等を人確認なしで変更しない。 | PASS |
| Q73 | 固定menuは 今日/入力/追加/お願い/共有/その他。追加は万能入口。 | `process-line-inbox` + shared LINE builders/pending-action canonical RPCs | `lineConversation.test.ts`; `lineMultiIntent.test.ts`; `lineMessageBuilders.test.ts`; SQL 62–65 | 家庭でこの条件が発生したとき、固定menuは 今日/入力/追加/お願い/共有/その他。追加は万能入口動作になることをUI/commandで確認。 | PASS |
| Q74 | 追加は自由入力主役+shortcut。 | `QuickAdd.tsx` / task form + canonical task adapters | `QuickAdd.test.ts` + task adapter SQL/Web tests | 家庭でこの条件が発生したとき、追加は自由入力主役+shortcut動作になることをUI/commandで確認。 | PASS |
| Q75 | Todayは現在時刻に合わせて内容と順序を再計算。 | `Today.tsx` + `useTodayData.ts` daypart/priority/read-model composition | `Today.test.tsx`; `TodayEvening.test.tsx` | 家庭でこの条件が発生したとき、Todayは現在時刻に合わせて内容と順序を再計算動作になることをUI/commandで確認。 | PASS |
| Q76 | 入力は今最も自然な対象を最初に出し、他へ切替可能。 | `CheckinPage.tsx` / routine-session canonical reconciliation commands | check-in/routine Web tests + canonical reconciliation SQL/concurrency suite | 家庭でこの条件が発生したとき、入力は今最も自然な対象を最初に出し、他へ切替可能動作になることをUI/commandで確認。 | PASS |
| Q77 | その他は管理/一覧/設定系。 | `AppShell.tsx` / Settings routes keep management/list/settings under secondary navigation | routing/AppShell tests in Web suite | 家庭でこの条件が発生したとき、その他は管理/一覧/設定系動作になることをUI/commandで確認。 | PASS |
| Q78 | LINE→PWAは該当作業へdeep linkし状態継承。 | `process-line-inbox` + shared LINE builders/pending-action canonical RPCs | `lineConversation.test.ts`; `lineMultiIntent.test.ts`; `lineMessageBuilders.test.ts`; SQL 62–65 | 家庭でこの条件が発生したとき、LINE→PWAは該当作業へdeep linkし状態継承動作になることをUI/commandで確認。 | PASS |
| Q79 | PWA完了を自分LINEへ返送しない。 | `process-line-inbox` + shared LINE builders/pending-action canonical RPCs | `lineConversation.test.ts`; `lineMultiIntent.test.ts`; `lineMessageBuilders.test.ts`; SQL 62–65 | 家庭でこの条件が発生したとき、PWA完了を自分LINEへ返送しない動作になることをUI/commandで確認。 | PASS |
| Q80 | 同一操作からの通知は1通にまとめ、返答必要を最上部。 | `process-line-inbox` + shared LINE builders/pending-action canonical RPCs | `lineConversation.test.ts`; `lineMultiIntent.test.ts`; `lineMessageBuilders.test.ts`; SQL 62–65 | 家庭でこの条件が発生したとき、同一操作からの通知は1通にまとめ、返答必要を最上部動作になることをUI/commandで確認。 | PASS |
| Q81 | 重複候補を検出し、勝手に統合しない。 | canonical mutation receipts/state-machine duplicate/delete-vs-terminal-state guards | idempotency/stale/terminal-state SQL suite + concurrency suite | 家庭でこの条件が発生したとき、重複候補を検出し、勝手に統合しない動作になることをUI/commandで確認。 | PASS |
| Q82 | 登録ミスだけ削除。他は不要/中止等の状態を残す。 | canonical mutation receipts/state-machine duplicate/delete-vs-terminal-state guards | idempotency/stale/terminal-state SQL suite + concurrency suite | 家庭でこの条件が発生したとき、登録ミスだけ削除。他は不要/中止等の状態を残す動作になることをUI/commandで確認。 | PASS |
| Q83 | 相手担当変更時は事前調整済みか確認。実績入力だけなら不要。 | planning/assignment UI + canonical rule/assignment commands and notification policy | planning/assignment Web + DB policy/regression tests | 家庭でこの条件が発生したとき、相手担当変更時は事前調整済みか確認。実績入力だけなら不要動作になることをUI/commandで確認。 | PASS |
| Q84 | アプリ外で調整済みなら申告で確定し監査履歴を残す。重要変更は相手に非ブロッキング訂正導線 `[違う]` を出す。 | planning/assignment UI + canonical rule/assignment commands and notification policy | planning/assignment Web + DB policy/regression tests | 家庭でこの条件が発生したとき、アプリ外で調整済みなら申告で確定し監査履歴を残し、重要変更は相手に非ブロッキング訂正導線を出す。 | PASS |
| Q85 | 重要な調整済み変更は随時通知、軽微は定時下部。 | planning/assignment UI + canonical rule/assignment commands and notification policy | planning/assignment Web + DB policy/regression tests | 家庭でこの条件が発生したとき、重要な調整済み変更は随時通知、軽微は定時下部動作になることをUI/commandで確認。 | PASS |
| Q86 | 随時/定時の判定は種類・日時・影響度から自動。 | planning/assignment UI + canonical rule/assignment commands and notification policy | planning/assignment Web + DB policy/regression tests | 家庭でこの条件が発生したとき、随時/定時の判定は種類・日時・影響度から自動動作になることをUI/commandで確認。 | PASS |
| Q87 | 夜は朝完了タスクを再掲せず、 `朝 n/n完了` 程度。問題だけ具体表示。 | `Today.tsx` + `useTodayData.ts` daypart/priority/read-model composition | `Today.test.tsx`; `TodayEvening.test.tsx` | 夜Todayでは朝の完了行を再掲せず『朝 5/5完了』、未完なら問題行だけ見せる。 | PASS |
| Q88 | 朝定時は平日6:30、土日祝9:00。 | notification/DailyBrief scheduling and delivery policy | notification/DailyBrief scheduler SQL/Edge tests | 家庭でこの条件が発生したとき、朝定時は平日6:30、土日祝9:00動作になることをUI/commandで確認。 | PASS |
| Q89 | 園画像から予定/共有/準備ToDoまで提案し確認後登録。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 園のおたより画像をLINEで送り、候補をレビュー・確認して初めて予定/共有/準備ToDoへ反映する。 | PASS |
| Q90 | 園/子/クラスは画像から自動判定、曖昧時だけ確認。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 画像の園/子/クラスが一意なら自動選択し、曖昧なときだけ確認する。 | PASS |
| Q91 | ユーザー確認済みの園別準備ルールを学習。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 一度確認した園別準備ルールを次のおたより候補生成に利用する。 | PASS |
| Q92 | 元画像を出典として紐づけ、後から画像だけ整理可能。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 確認済みデータは残したまま、後日raw画像だけ削除できる。 | PASS |
| Q93 | 他クラス/他児童の情報は家庭データへ取り込まない。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 別クラス/別児童の記載を対象児の家庭データへ混入させない。 | PASS |
| Q94 | 後続お知らせによる変更を既存予定/準備までまとめて更新候補化。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 後続のおたよりで日時等が変われば、既存予定/準備の差分更新候補を出す。 | PASS |
| Q95 | 人の確定値と新情報が競合したら差分確認。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 以前人が確定した値と新情報が違う場合、silent overwriteせず差分確認する。 | PASS |
| Q96 | LINE画像送信時に軽判定し、お知らせらしい時だけ解析候補。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 普通の家族写真はおたより解析へ進めず、おたよりらしい画像だけ候補化する。 | PASS |
| Q97 | 明記情報とAI推測を明確に分離。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 画面で『明記』と『AI推測』の出所を区別して確認できる。 | PASS |
| Q98 | 連続画像を同一資料候補としてまとめて解析可能。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | おたより2ページを別worker batchで受けても、前ページをDBから復元し同一資料page1/page2としてまとめる。 | PASS |
| Q99 | AI解析は候補を1画面確認し、項目単位修正。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 抽出候補を1画面で見て、項目ごとに修正/採用して確定する。 | PASS |
| Q100 | 元画像は家庭詳細から双方閲覧可、LINEへ再送しない。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 夫婦が家庭詳細から元画像を見られるが、閲覧のためLINEへ画像を再送しない。 | PASS |
| Q101 | 月間予定表は家庭影響度の高い予定をおすすめ、その他も確認可能。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 月間候補では家庭影響が高い予定をRecommendedにし、Otherも捨てず確認できる。 | PASS |
| Q102 | 画像中の毎週/期間ルールを期間付き定例候補化。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 『毎週金曜・年度末まで』等を期間付き定例候補として確認する。 | PASS |
| Q103 | 定例の特定日中止/変更はその回だけ例外化。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 定例の1日だけ中止/変更してもseries全体を書き換えない。 | PASS |
| Q104 | 提出物は期限付きToDo、Calendarは任意。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 提出期限はToDoに持ち、ユーザーが必要と選んだ場合だけCalendarへ出す。 | PASS |
| Q105 | URL/QR/提出先をToDoの実行先として紐づけ可能。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 提出ToDoから安全なhttps URL/QR先へ進め、javascript等は拒否する。 | PASS |
| Q106 | 完了証跡は任意添付。通常完了は1tap。 | `NurseryReviewPage.tsx` + DD9 nursery intake/review/confirm/source pipeline | SQL 66–72 nursery E2E + `NurseryReviewPage.test.tsx` | 通常は完了1tapで終わり、必要なときだけ後からメモ/画像証跡を追加する。 | PASS |
| Q107 | `誰でもOK` を正式担当種別にする。 | `Shopping.tsx` + canonical shopping claim lifecycle | `71_shopping_anyone_claim_lifecycle.sql` + Shopping action tests | 買い物を『誰でもOK』で登録すると、最初は誰にもclaimされない。 | PASS |
| Q108 | `誰でもOK` は実施前に `[自分がやる]` でclaimする。claim者不在時は必要時だけtakeover可能。 | `Shopping.tsx` + canonical shopping claim lifecycle | `71_shopping_anyone_claim_lifecycle.sql` + Shopping action tests | 買う人が『自分がやる』でclaimし、必要時だけ別の大人がtakeoverする。 | PASS |
| Q109 | claim後は本人が手放せる。期限で自動解除しない。 | `Shopping.tsx` + canonical shopping claim lifecycle | `71_shopping_anyone_claim_lifecycle.sql` + Shopping action tests | claimは時間経過では消えず、現在claim者本人だけが手放せる。 | PASS |
| Q110 | Google日時変更は予定へ反映し、関連準備は変更候補。 | `GoogleEventReviewPage.tsx` + Google cache/review/authority pipeline | `73_google_human_confirmed_diff_review.sql` + Google projection/isolation tests | Googleで日時を変更しても人確定値を黙って上書きせず、差分レビューから明示反映する。 | PASS |
| Q111 | Google削除は中止/日程変更待ち/Googleのみ非表示を確認。 | `GoogleEventReviewPage.tsx` + Google cache/review/authority pipeline | `73_google_human_confirmed_diff_review.sql` + Google projection/isolation tests | Googleで削除されてもFamily Ops予定を即削除せず、扱いを人に確認する。 | PASS |
| Q112 | Google重複候補は既存予定へのlinkか別追加を確認。 | `GoogleEventReviewPage.tsx` + Google cache/review/authority pipeline | `73_google_human_confirmed_diff_review.sql` + Google projection/isolation tests | Googleの重複候補は自動mergeせず、『同じ予定/別の予定』を人が選ぶ。 | PASS |

## Final counts

- PASS: **112**
- GATED Qs: **0**
- GAP: **0**
- UI_GAP: **0**
- RUNTIME_GAP: **0**
- TEST_GAP: **0**
- USER_DECISION_REQUIRED: **0**

## Cross-Q / release-gate notes

### H6-A — LINE conversational coherence source/runtime
**PASS.** Natural-language create/request/share flows return a concrete in-LINE preview; ambiguous input asks only for missing information; `なにを？` / `何を受け付けたの？` / `さっきの何？` resolves against the sender/household/actor-scoped latest relevant pending action without mutation; draft/processing/registered/terminal states are distinguished; stale/out-of-order edits fail closed.

### H6-B — real LINE manual transcript
**GATED (release gate, not a Q implementation gap).** A real-provider transcript is deliberately not executed before independent source GO because real LINE send/provider mutation is prohibited for this PR closeout. After source GO, run the H6 transcript against the reviewed build before spouse rollout.

### Real-device spouse-rollout evidence
375×667 and 393×852 / real-iPhone screenshot capture remains a post-source-review rollout gate. It does not mask a Q1–Q112 implementation gap; the source/UI component coverage is complete at this handoff.

### Nursery Q89–Q106
**PASS.** In particular, Q98 is the literal continuous-multiple-image requirement: a later worker invocation recovers the previous page from durable DB state and groups both pages into one document candidate, proven by `67_nursery_q89_q98_canonical_completion.sql`.

### Safety / integrity
- Idempotency: PASS.
- Household/test-context isolation: PASS.
- Concurrency: PASS.
- Provider mutation fence: PASS.
- DD11 readiness audits: PASS / zero leakage.
- Generic `private.fn_claim_canonical_operation_v1` remains unavailable for direct `service_role`/browser execution; only fixed-shape transport server commands enter the internal receipt boundary through the hardened command wrapper.
