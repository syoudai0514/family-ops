# ASTRA Purpose / Product / UX independent review
Status: INDEPENDENT REVIEW DRAFT — non-canonical, checkpoint 2. Date: 2026-09-17.
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

## E–F. 大きなズレと日常負担（候補、checkpoint 3で確定）
| ID | 優先 | 分類候補 | 日常上の問題 | CURRENT根拠 |
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
本レビューはCURRENTソース・GitHub run metadata・保存済みF2資料からのdesk review。実ブラウザ表示、実機・provider・DB稼働は未検証。次checkpointで関連テスト、通知、routine bulk、LINE入口を追い、反証を加えてfindingを確定する。詳細設計はレビュー確定・push後に開始する。
