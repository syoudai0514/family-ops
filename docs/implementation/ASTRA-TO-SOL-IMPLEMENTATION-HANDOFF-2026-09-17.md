# ASTRA → ChatGPT Sol implementation handoff
Status: READY FOR CONFORMING IMPLEMENTATION / PROPOSED DESIGN
Date: 2026-09-17
Reviewed main: `900313187c2460901f91d8aea66051e57729b50b`
Review branch: `review/astra-purpose-ux-20260917`
Production mutation: NO. Main merge: NO. Physical F2: NOT PERFORMED.

## 読む順番
1. CURRENT GitHub + canonical Requirements / scoped Accepted ADR / current design
2. [独立Purpose review](../reviews/ASTRA-PURPOSE-UX-REVIEW-2026-09-17.md)
3. [PROPOSED詳細設計](../proposals/ASTRA-PURPOSE-UX-PROPOSED-DESIGN-2026-09-17.md)
4. [CURRENT inventory / checkpoints](../reviews/ASTRA-PURPOSE-UX-INVENTORY-2026-09-17.md)

## 実装可能scope
PF-01/02/03/04/07の5件（S0–S3）。PF-05/06はそれぞれPO-01/02の明示承認がない限り実装しない。レビューと設計自体は完成しており、この2件を未承認のまま実装する必要はない。

| ID | 結論 | 実装成果 |
|---|---|---|
| PF-02 | 確認と送信の正文を一致 | immutable confirmed command、原文fallback排除 |
| PF-07 | 入力意味をLINE/PWAで保持 | pickup既存担当変更・subtasks/context/visibility |
| PF-04 | 永久待機と結果不明を回復 | bounded client、同一操作retry、入力保持 |
| PF-01 | 入力前の分類を減らす | +から入力、1画面review、手動入口維持 |
| PF-03 | Codmon残入力を理解可能に | shared readiness、送信task inline表示 |
| PF-05 | PO-01待ち | PWAの限定相談返答 |
| PF-06 | PO-02待ち | Codmon送信だけbulk除外・専用1tap |

## そのままSolへ貼る実装依頼文
以下のコードブロック全体を新しいチャットへ貼ってください。refが進んだ場合はCURRENTを優先し、本書に書いたSHAを最新と決めつけない。

```text
============================================================
Family Ops / おうちノート
SOL PURPOSE-FIRST IMPLEMENTATION
ASTRA REVIEW → CONFORMING FIXES → MERGE-READY
============================================================

repository: syoudai0514/family-ops
reviewed main anchor: 900313187c2460901f91d8aea66051e57729b50b
review branch: review/astra-purpose-ux-20260917

最初にCURRENT GitHubをfresh-readしてください。
actual main HEAD、作業branch/HEAD、open/recent PR、changed files、CI、
canonical Requirements、Accepted ADR、docs/design/currentを確認すること。
anchor・この依頼文・旧PR本文・過去CIをCURRENT truthにしないこと。

読む成果物（review branchから取得。mainには未merge）:
docs/reviews/ASTRA-PURPOSE-UX-INVENTORY-2026-09-17.md
docs/reviews/ASTRA-PURPOSE-UX-REVIEW-2026-09-17.md
docs/proposals/ASTRA-PURPOSE-UX-PROPOSED-DESIGN-2026-09-17.md
docs/implementation/ASTRA-TO-SOL-IMPLEMENTATION-HANDOFF-2026-09-17.md

0. 成功条件
おうちノートは家事ticket管理ではない。
家族が「覚える」「分類する」「相手に再確認する」「送れたか不安になる」
負担を減らすための共有記憶・調整支援である。
Purpose → Requirements → UX → detailed design → implementationの順を守る。
機能数、コード整理、test件数、CI GREENだけで完了にしない。

1. 今回実装するscope
PF-01: ＋追加を自由入力主役にし、10分類modalを最初に要求しない。
PF-02: previewした相手・正文・対象・日時・副作用と実送信payloadを一致。
PF-03: Codmon送信taskに残入力・担当・readinessをinline表示。共通DB読取。
PF-04: APIのauth/fetch/body永久待機を解消し、結果不明を同じoperation IDで確認。
PF-07: 自然文の既存pickup変更・準備subtasks/context/visibilityを
       LINE/PWA/単一/複数candidateからcanonical commandまで保持。
詳細はPROPOSED design §§5–9,12–15を採用候補としてCURRENT正本と照合する。
S0→S1(PF-07/02/01)→S2(PF-04)→S3(PF-03)の単位でcommit/pushする。

特にPF-02はCURRENTのmock実行で反例再現済み:
title/dateを火曜から水曜に編集しても、旧sharedMessageが送信payloadに残る。
生入力sourceTextを未確認の相手向け正文にfallbackしてはいけない。

PF-07は「新しいお願い」と「既存のお迎え担当変更」を混ぜない。
Request作成/相談開始では担当を変更せず、受理後だけ既存dependency処理を使う。
曖昧/対象なしを軽いお願いに黙って変換しない。

2. PO未承認のSTOP範囲
PO-01 / PF-05: PWAにも限定的な相談回答を返す製品scope追加。
PO-02 / PF-06: コドモン最終送信を一般group完了から除外する例外。
この2件は明示承認がCURRENT canonicalまたはこのセッションに存在する場合のみ、
承認内容をRequirements/current designに反映する同じPRで実装する。
承認がなければDEFERREDと記録して対象外。ほかの5件を止めない。
review/proposalの存在や「このhandoffを実施」はPO承認の代用ではない。

全体STOP:
- top-level canonical requirements / Accepted ADRの真の競合
- 外部費用、production mutation、production deploy、main merge、
  実妻への通知、Physical F2操作が必要になる場合
- 目的/UX/責務分類を変更しないと設計を成立させられない場合
該当しないconforming作業と資料整備は継続する。

3. CURRENT / branch
fresh-readでmainがanchorから進んでいたら対象path差分を確認し、
修正済みfindingは再実装せず証拠付きで閉じる。
独立implementation branchをCURRENT mainから作る。
review branchの成果物4ファイルを必要ならそのbranchへ持ち込み、
レビューbranch全体の古いアプリ状態をmainへ上書きしない。
AGENTS/START-HERE等が追加されていれば先に読む。
正本はADR0012/0013のscope ruleで確定。古いpendingヘッダだけで
merged Requirementsを無効扱いしない。

4. 設計の守るべき境界
- existing domain / Edge commands / ActorRef / context / receipt / CASを再利用。
- assignment actual recorder claim acknowledgementを混ぜない。
- Request合意前は現在担当維持、accept後はlinked Taskが実行truth。
- 一つのconfirmed envelopeからpreviewとcommandを作る。
- unknown responseは「失敗で未送信」と言わない。
- retryは同じID/同じpayload。timeoutだけ追加して新ID再送を放置しない。
- Codmonは入力/送信申告だけ。食事・健康本文の二重保存、provider自動送信なし。
- readinessは固定4codeの存在＋completed。同じ日/household/test context。
- LINE MUST completeをPWAへ押し出さない。業務ルールのchannel分岐なし。
- 追加push・200通上限緩和・採点dashboardを入れない。
- expired/stale/duplicate/partial/offline/user switchで誤送信しない。
- existing migrationを書き換えない。新migrationは現在のCLI手順で生成する。
- production DBのQ113適用済みをmain mergeやVercel successから推測しない。

5. 実装と検証
調査で止まらず、
CURRENT確認 → finding/Q/設計mapping → 実装
→ targeted tests → full CI → failure原因修正 → 再CI
→ self-review → canonical docs/implementation report更新
→ commit/push → PR → merge-readyまで継続。

対象:
S1: shared candidate resolver、assignment-change CAS v2、subtasks保持、
    confirmedCommand、単一review workspace、input-first QuickAdd。
S2: 共通API deadline、CommandAttempt recovery、
    Requests/Concierge/Today task/Checkin/Shopping/Handovers/Nursery/TaskForm。
S3: additive Codmon readiness helper、DailyBrief、submit guard/reminder共通定義、
    PWA/LINE inline表示。
新module/API/state/test/rolloutはPROPOSED designを参照。
技術都合で新しいドメインや会話DBに作り直さない。

試験は最低限design A01–A12/A15。
A13/A14はPO承認時のみ。
- raw input → proposal → preview → transported command → canonical readback
- 火曜→水曜修正、宛先修正、相談/送信禁止/混在
- existing pickup accept前後、dependent/protected tasks
- 準備物2項目が実際に登録される
- DB成功/HTTP応答消失の同一ID再試行でRequest・通知1回
- auth/fetch/body永久pendingとlate response、refresh/Back、user switch
- Codmon4input、missing row、休日、9:00 dedup、9:15 guard
- Shopping/園画像/朝夜groupの非劣化

unitだけ/fixture candidateだけ/文字列存在checkだけでPASSにしない。
local commandsはCURRENT package/workflowを読んで実行する。
参考: npm run lint / typecheck / test / build / test:sql /
test:cf14:authoring / test:cf14:browser とEdge deno tests。
full CIはweb/db/edge/Supabase/evidence・Operational Safetyを確認。
失敗が既存の無関係workflowなら証拠付きで区別し、
保護を弱めて「全GREEN」にしない。

6. Docs / checkpoint
意味のある単位でcommit/push。最後にまとめて保存は禁止。
コードとcanonical detailed designの対応更新を同じPRにする。
metadata driftは事実のみ修正。未承認PF-05/06はcanonicalへ入れない。
Requirements変更なら変更理由とPO承認根拠を明記する。
途中終了時はWIP/NEXT ACTION/exact HEADを保存する。
参考となる旧testsやPR説明をCURRENT完了証拠に転用しない。

7. 終了境界
本依頼ではmain merge・production deploy/mutation・Physical F2はしない。
PRをmerge-readyにして、レビューと必要F2の対象を具体化する。
source/testで閉じたものとphysical evidence待ちを分ける。
最後にCURRENT main/branch/PR/final exact HEAD、
対応PF/Q、変更files/migration、tests/CI、
PO保留項目、未解決点、F2/rollout影響、
production mutation NO、main merge NOを報告する。
============================================================
```

## Evidence carried forward
- Reviewed main CI #1242 SUCCESS、Operational Safety #337 SUCCESSをGitHubからfresh-read。
- Kick LINE UX v5 #76 FAILUREも存在。全workflow GREENとは報告しない。
- ローカルのmock invocationでPF-02の編集title/dateと旧sharedMessageの不一致を再現。
- 同じmock環境でduplicate existingがwriteしないことを確認。
- フルproduct testsの再実行、実ブラウザ/F2、production DB/Edge適用状況の確認は未実施。
- Review成果物はdocs-only。merge/release approvalは含まない。

## 次工程の最初の判断
「mainがこのreviewから変わったか」「PF-01/02/03/04/07はまだ存在するか」
をCURRENTで確かめる。古い証拠を固定して直すのではなく、Purposeを固定してCURRENT差分を扱う。
