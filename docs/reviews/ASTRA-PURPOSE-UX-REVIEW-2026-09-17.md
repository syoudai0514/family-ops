# ASTRA Purpose / Product / UX independent review
Status: INDEPENDENT REVIEW COMPLETE — non-canonical, checkpoint 3. Date: 2026-09-17.
Reviewed main: `900313187c2460901f91d8aea66051e57729b50b`.
Branch: `review/astra-purpose-ux-20260917`.
See [inventory](ASTRA-PURPOSE-UX-INVENTORY-2026-09-17.md) for authority and CI evidence. No Physical F2 or production access performed.

## A. 初見の理解
家庭の仕事を単に一覧にするアプリではなく、LINEで日常の相談・依頼・確認を行い、PWAで詳しい状況を確認する「家庭の共有記憶」である。ただしPWAの入口では、利用者に仕事の種類と登録機構を先に理解させる印象が残る。

## B. 本来のPurpose
「覚えておく」「相手に伝える」「誰がやるか確かめる」という家庭内の見えない仕事を減らす。アプリへの入力、確認、通知処理という新しい仕事が、減らした負担を上回ってはいけない。判断が必要な同意・送信だけを人に残し、表示と整理はシステムが引き受ける。

## C. CURRENT評価
方向性と業務上の安全境界は強い。一方、普通に入力して安心して閉じるという一連の体験は未収束。実装量やCIの成功から「普通の夫婦が毎日無理なく使える」とはまだ判定できない。ソース上のmaterial gapとPhysical F2未確認を分けて扱う。過去のF2証跡やreview GOをこのHEADのproduct PASSに転用しない。

## D. 良いところ
- Requestが合意、linked Taskが実行という分離。相手の沈黙や相談開始を了承にしない。
- 予定担当／実施者／記録者／誰でもOKのclaimを区別。夫婦の実態を誤って採点しにくい。
- Todayの独立KPIと相手の完了スコアを除去済み。単一DailyBriefと時間帯別表示を採用。
- 「大体やった」は子を一括完了しない。不明を失敗と決めつけない。
- LINEの相談／送信禁止の検出、安全な候補化、既存データの重複確認、明示確認がある。
- Codmonフォームを複製せず、入力／送信の申告と09:15締切を支える設計。これは二重入力を避ける良い判断。
- PWA再開時のSW確認、更新ボタン、pull refresh、既存家庭shell維持がある。以前の未修正状態として批判しない。

## E–F. 大きなズレと日常負担（確定）
| ID | 優先 | 分類 | 日常上の問題 | CURRENT根拠 |
|---|---|---|---|---|
| PF-01 | P1 / 毎日の入力 | CONFORMING FIX | 追加を押しても書き始められず、10種類の選択を挟む。AIが「別機能」になり内部用語も露出 | QuickAdd.tsx / ConciergePage.tsx / ConciergeConfirmPage.tsx |
| PF-02 | P0 / 相手への誤送信防止 | IMPLEMENTATION DEFECT | Concierge確認画面がtitle/sourceText中心で、送信するsharedMessage、宛先、時刻を同じ内容として確認できない。title編集だけでsharedMessageは旧内容のまま | ConciergeResultsPage.saveEdit、ConciergeConfirmPage、conciergeCommit request/share分岐 |
| PF-03 | P1 / 毎朝09:15 | CONFORMING FIX | Codmon送信前に「誰のどの入力が残るか」を同一作業の文脈で読めず、押してエラーで知る構造。通常taskに紛れる | design12 readiness / useTodayData / TaskChecklistItem / migration Q113 |
| PF-04 | P1 / 信頼・継続利用 | IMPLEMENTATION DEFECT | 登録/送信のAPI helperはgetSession/fetch/body readに上限なし。待ちっぱなしのbusy UIから更新すると、成功したか分からないまま再入力し得る | apiClient.callEdgeFunction / Requests.SendRequestForm / conciergeCommit |
| PF-05 | P2 / 言いづらい相談 | PRODUCT PROPOSAL | PWA自由入力は相談を安全に候補から除外できても、有用な相談回答を返さず「具体的に追加」と戻す。LINEにある会話援助をPWAにも出すか | propose-concierge-candidates / lineAssistantConversation / ConciergeResultsPage |
| PF-06 | P1 / critical acknowledgement | PRODUCT PROPOSAL | Codmon最終送信が通常朝group対象。「全部やった」の中の一件として扱う方針と、外部送信忘れを防ぐ方針のどちらを優先するか | Q59/Q64/Q113 / seed include_in_routine_line=true / submit trigger |

P0は本番事故確認済みという意味ではない。PF-02は人が承認した本文と実際の副作用の一致を先に直す優先順位。
PF-06の現行bulkを「明白なバグ」と断定しない。現行は列挙された対象をまとめて申告できる契約であり、その例外化にはPO判断が必要。

## G. 重要な方向性
入口を少なくし、入力内容に応じた必要な確認だけにする。AIは分類のための別製品にせず、普通の入力の補助にする。Todayは新しいdashboardではなく、残っている現実の行動を具体的にする。家族が見る確認には「誰に何が届くか」を表示し、DB/RPC/revision/operation IDなどの実装説明を混ぜない。

## H. 変えてはいけない部分
同意前の担当維持、変更scope、protected human values、子タスクの不明状態、claim、個別訂正、重複CAS、同一canonical command、LINE MUST complete、PWA操作のLINE自己通知禁止、200通hard cap、実妻への検証通知禁止。Codmon自動送信、健康・食事本文のFamily Opsへの二重保存、追加pushは今回提案しない。

## I. 現段階の証拠限界
本レビューはCURRENTソース・GitHub run metadata・保存済みF2資料からのdesk review。実ブラウザ表示、実機・provider・DB稼働は未検証。関連テスト、通知、routine bulk、LINE入口を追加確認した。以下を確定レビューとし、このcheckpointのpush後に詳細設計を開始する。

## Findings詳細と反証

### PF-01 — 入力前に分類を要求する（P1、conforming UX fix）
**Requirements:** §3.1/3.7、Q70/Q71/Q73/Q74、M02。**Evidence:** `apps/web/src/features/tasks/QuickAdd.tsx` のbuttonは必ず `setOpen(true)` → `quickAddOptions` 10選択肢。自由入力はさらにconciergeを選択して初めて表示。Todayとbottom navが同じ入口を使用する。
既存の自由入力機能がないという指摘ではない。最初に使い方を考えさせる階層が、自由入力主役の目的に逆行している。毎日の牛乳追加・お迎え相談・園情報入力に頻発する。直す対象は入口の順序と利用者向け説明であり、分類モデルやドメインを増やさない。
認知上の理由: 思いついた内容を保持しながら種類を選ぶと、記憶保持と分類という二つの仕事になる。まず書いてから分類結果を認識・修正する順にする。一般的な設計推論であり、本家庭で効果測定済みという主張ではない。
**Acceptance:** 追加から直接入力可。手動ToDo・画像・実績等へのアクセスは維持。戻ると入力と元スクロールが残る。英語の内部機構説明は家族向け文面へ置換。Q70の「1画面でまとめて確認」に合わせ、同じ候補を二画面で再承認させない（PF-02と同時実装）。

### PF-02 — 確認内容と送信payloadのズレ（P0、proven implementation defect）
**Requirements:** §3.6/§7/§16、Q70/Q71、M02/M04/M05、design05 human-confirmed authority。
**Evidence:** `ConciergeResultsPage.saveEdit` はtitleとscheduledDateを変えるがsharedMessageは変えない。`ConciergeConfirmPage` はtitle/sourceText/dateを表示し、request送信のsharedMessage・宛先・dueLocalTimeを最終表示していない。`conciergeCommit.commitConciergeCandidate` はrequestで `sharedMessage.trim() || sourceText` を送る。sourceTextは生入力であり、送信正文の保証ではない。
**Counterexample reproduced locally:** CURRENTの `conciergeCommit.ts` をTypeScript transpileして、mock Edgeを注入。編集後title「水曜のお迎え」、date 2026-09-23、旧sharedMessage「火曜のお迎えをお願いできますか？」を渡すと、異なる曜日のtitle/messageが同時に送信payloadへ入る。外部送信なし。UI全体のE2Eではなく、UI編集コードとの組合せに対する実行確認。
**反証:** 専用Requests画面には柔らかい文案の確認があり、LINEにも安全判定がある。全経路で無断送信が起きるとは述べない。問題はPWA万能入力経路の最終確認が実payloadを保証していないこと。
**Acceptance:** 一つのimmutable confirmed commandからpreviewと送信を作る。送信正文・相手・日時・副作用を表示。生入力を暗黙の送信fallbackにしない。編集で再確認、再試行で同一operation IDとpayload、部分成功の重複なし。

### PF-03 — Codmonの依存状態を家庭に翻訳する（P1、conforming UX fix + defensive consistency）
**Requirements:** §2/§3、Q1/Q23/Q69/Q113、design12。**Evidence:** Q113 migrationの4入力+送信guardは存在し、`errors.ts` は409と「残っている入力を先に完了」の説明を既に持つ。これを未実装と指摘しない。しかしTodayのDailyBrief型/TaskChecklistItemにCodmonの全4項目readinessや残担当を表示する契約がなく、通常taskのチェック操作から拒否されて初めて不足が分かる。
自分の担当中心の表示は良いが、送信者が待っている相手の入力状態を再構成する負担が残る。新dashboardではなく、送信taskそのものに「残り: 朝食（自分）/ 昨日の様子（相手）」を添える。
追加の限定的整合性: reminderは「存在する未完了行」のcount=0をready判定に使うが、submit guardは必須4 codeのcompletedを数える。欠落行がある場合、前者だけreadyにできる。欠落が通常運用で発生したという証拠はないが、同じreadiness定義へ寄せて誤った「そろいました」を防ぐ。
**Acceptance:** 4codeの存在＋completedを同一date/contextで検証。欠落は未取得/未生成であり完了扱いしない。新しいpushやCodmonフォーム複製は不要。既存の9:00通知数と同意境界は維持。

### PF-04 — 待ちっぱなしと「送れたか不明」を分けて回復する（P1、proven source defect）
**Requirements:** §3.8、Q78/Q79、§28.1のPWA recovery、current design04 recovery。
**Evidence:** `apiClient.callEdgeFunction` はgetSession→fetch→response.textのどこにもdeadlineがない。画面のfinallyはPromise完了待ちのため、登録・お願い・チェック・おたより確認等がbusyのままになり得る。`Requests.SendRequestForm.handleSubmit` は呼ぶたびにnewOperationIdを発行する。Conciergeは既存operation IDを再利用できる良い例。
**反証:** 初期auth/household/Todayの12秒timeout、8秒loading recovery、手動/Pull refresh、SW更新対策は既にある。これらを再実装しない。本findingは共通Edge clientと、その結果不明時のmutation再試行境界。
**Acceptance:** 時間が来たら再操作可能になる。ただし「失敗＝未送信」と誤表示しない。受理済みか不明なら同じID/同じpayloadで確認兼再試行し、新しい依頼を発行しない。未送信と分かるvalidation errorのみ編集可能。既存shell/navを保ち、更新前に未確定入力を保護する。

### PF-05 — PWAにも相談の返答を出す（P2、PRODUCT / REQUIREMENT CHANGE PROPOSAL）
**CURRENT:** LINE §28.3は相談応答を要求し、`buildAssistantConversationReply` とfallbackが存在する。PWAは同一decompositionのno-actionを受け、`propose-concierge-candidates` が「追加・共有したい内容を…」を返す。`ConciergeResultsPage` は候補なしで言い換えを求める。安全なno-actionを破ってはいない。
**Purpose gap:** 「何でも書いて」に言いづらいことを相談した人が、自分の入力ミスと思う。
**提案/PO-01:** PWAにもLINEと同じ限定的な家族コミュニケーション相談を返す。汎用チャット、長期会話memory、AIからの自動送信は追加しない。今ある候補結果領域に短い返答を出し、文案をお願い候補に移すには新しい明示操作を要求する。
現行LINE義務をPWAにも広げるため、既存バグと混ぜずPO承認待ち。承認なしのSol対象外。

### PF-06 — コドモンの最終送信申告を一括完了から分離（P1、PRODUCT / REQUIREMENT CHANGE PROPOSAL）
**CURRENT:** Q59/Q64は意味のあるgroupの全部完了、Q113は4入力completed後の送信completed。seedは全5definitionをroutine対象にする。現行group commandはown/active/required-or-normalを対象とし、Codmon送信だけの例外は確認できない。
**Purpose gap:** 「朝の準備全部やった」という慣れた操作で、外部送信という最後の行動まで申告されると、忘れ防止の価値が弱い。これは注意の慣れに対する設計上の推論であり、誤完了事故の実測ではない。
**提案/PO-02:** 4入力は従来groupを許容。最終送信のみ一般group完了から除外し、「コドモンで送信した」を1tapで別申告。Codmonの画面を開くこと・4入力readyを送信成功にしない。
**Tradeoff:** 通常朝に最大1tap増える。9:15必須作業だけを意識的に閉じる利益と比較してPOが決める。Q59/Q64の例外、Q113、design03/04/12を同一PRで承認済み内容へ更新するまで実装禁止。通常task全般へ確認儀式を拡張しない。

## 横断traceabilityと実装順
| Finding | Purpose / requirement | 改善の最小単位 | test / F2 |
|---|---|---|---|
| PF-02 | 安心して相手に伝える / Q70, §3.6 | confirmed preview=command payload | 編集→送信のDOM/network一致、2者LINEで正文/対象確認 |
| PF-04 | 途中で諦めず使える / §28.1 | bounded wait + retry identity | never-resolving auth/fetch/body、response loss、再送1件、実機復帰 |
| PF-01 | 思いつきを外に出す / Q74 | input-first、確認統合 | +→入力→一括確認→結果、戻る/手動fallback |
| PF-03 | 朝の忘れ防止 / Q113 | read-only readiness、既存task inline説明 | SQL同一code定義、PWA/LINE表示、平日9:00/9:15 |
| PF-05 | 言いづらさを減らす / PO-01 | 承認後のみPWA相談応答 | 相談/禁止/混在/明示action、通知0 |
| PF-06 | 最終提出を忘れない / PO-02 | 承認後のみ送信taskのbulk除外 | LINE/PWA bulkとも除外、単独完了可、実機 |

合計: material findings **6**。Conforming work **4**（implementation defect 2、conforming UX refinement 2）。Requirement change proposal **2**、PO判断 **2**。統計上の実現率・UX合格率は算出しない。

## 通知・周辺機能の評価
Shoppingはopenを前面、historyを折り畳み、claim/action-level actualを持つ。Nursery画像は出典、曖昧な子/園、候補選択、画像のみ削除を持つ。今回はこれらを新しく作り直す理由はない。PF-04の共通通信回復とPF-02の確認整合は周辺にも非劣化確認を適用する。
通知は既存quota予約、reply-first、重複排除、business expiry、in-app fallbackを維持。Codmon追加後の月間余裕は実利用で確認すべきだが、quota消費実測なしに通知削減や増枠を要件化しない。9:10追加reminder、相手の毎完了push、採点表示は提案しない。
LINEの相談安全性・混在入力corpusはPWAにも再利用できるが、既存test PASSはPWA entry-to-sendの証明ではない。

## Governance / evidence maintenance（material件数に加算しない）
1. root READMEの旧実装範囲・6functions表記、Baseline pending mergeヘッダ、ADR indexの0014 pending記載はCURRENTと不整合。正本を複製せず、Solが事実のmetadataだけ同一PRで修正する。製品仕様変更ではない。
2. current-design内の同名番号08/10は異なるscopeの文書。複数CURRENT truthを選ばずindexとADR scopeに従う。未解消semantic conflictが見つかれば該当項目をSTOP。
3. F2 handoff §7.4–7.7にはAndroid復旧とQ113の実証待ち。履歴日付が古くても最新ソースの該当状態は証拠として読んだが、現在の実機状態を断定しない。
4. CI #1242 / Operational Safety #337はsuccess。Kick LINE UX v5 #76はfailure（Trigger apply step）。CURRENT workflowは既にtreeにない `_apply-line-ux-v5.yml` に追記しmainへpushしようとする。今回実行・修正はしない。終了済み一回処理なら別途運用担当が廃止判断し、保護を弱めて成功させない。
5. open検索には過去stacked PR #72/#46が残る。本文の旧PASS・旧candidateをCURRENTに採用しない。今回の変更対象はreview/proposal/implementation docsだけ。

## Review conclusion
現状は「安全な部品は揃っているが、家族の入力から安心して閉じるまでの体験に切れ目がある」。機能を増やす前にPF-02/04/01/03を収束させる。PF-05/06は価値がある提案だが、POが選ぶまで現行要件を保持する。Product PASS / production readinessは未判定。ここまでのレビューを保存してからPROPOSED詳細設計へ進む。
