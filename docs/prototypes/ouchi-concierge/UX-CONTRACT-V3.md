# おうちノート UX Contract v3 — Today → 実行 → 実績

Status: user-directed UX contract candidate
Source baseline checked against PR #50 current head `364c0203c8e2c067769cbfb9a9629061c2ca89ed`.

## 1. Product goal

おうちノートの主目的は「実績を入力すること」ではない。

> 家族の毎日で **今、誰が何をすればよいかを考えなくても分かるようにし、実行した結果を最小操作で残す**。

UX priority is therefore:

1. 何をすべきか分かる
2. その場で実行・確認できる
3. 終わった結果を最小操作で残せる
4. 例外だけ詳しく扱う

`Today` is the operational home and primary surface. `おうちコンシェルジュ` is a universal ad-hoc input entry, not the primary operational home.

## 2. Non-negotiable navigation model

Preserve CURRENT bottom navigation:

- 今日
- 週
- 月
- 買い物
- 履歴
- ＋

Preserve CURRENT Quick Add options. Add `おうちコンシェルジュ` at the top of Quick Add without removing the existing explicit flows.

Today may also expose one small shortcut to the concierge, but it must not displace `今やること` / pending decisions / current operational work.

## 3. Today is the center of the product

### 3.1 Order of information

Today must prioritize information approximately as follows, subject to conditional absence:

1. `今やること` / current actionable work
2. response-needed requests / pending decisions when present
3. next time-sensitive schedule/action
4. current-day schedule and transport
5. current daypart's remaining routine work
6. compact progress from earlier dayparts
7. tomorrow-impacting preparation
8. partner critical summary
9. shopping summary
10. concierge shortcut / other utility entry without overpowering the above

This is not a rigid CSS order for every state. The requirement is that current actionability beats historical/completed detail.

### 3.2 Daypart-aware presentation

Morning example:

- `今やること` = 朝準備 / 送り
- show concrete unfinished items
- allow `朝の4件をまとめて完了` only after showing the 4 included items
- show next schedule below

Evening example:

- completed morning work collapses to `朝 4/4 完了`
- do not re-list completed morning items
- show unresolved/problem morning items concretely if needed
- `今やること` = remaining evening work
- tomorrow-impacting preparation stays visible

This preserves the canonical Q87 intent.

## 4. Core rule for aggregate actual input

### 4.1 Never show an unscoped `全部やった`

Before any aggregate button, the UI MUST display the exact scope being reconciled.

Bad:

```text
今日はどうでしたか？
[全部やった]
```

Good:

```text
今回の入力対象
夜の2件
- 洗濯
- お風呂掃除

[この2件を全部やった]
[大体やった]
[個別で答える]
```

The button label should include the scope when practical (`この2件`, `朝の4件`, `夜の2件`).

### 4.2 Normal operation should often finish inside Today

If Today already shows the exact active items, allow direct per-item `完了` and a scoped aggregate completion directly in the section.

Do not force users into a separate `実績入力` page merely to repeat information they can already see.

The separate check-in view remains useful for LINE deep links, reconciliation, previous-day entry and complex/exception cases.

## 5. Reconciliation semantics

Keep canonical three-way reconciliation for a meaningful group:

- `全部やった`
- `大体やった`
- `個別で答える`

### 5.1 全部やった

- scope must be shown before action
- commits normal included items immediately
- do not add a redundant confirmation page
- immediately after commit show:
  - `例外を修正`
  - `元に戻す`
- `余力があれば` items remain excluded as defined by canonical requirements

### 5.2 大体やった

- records group-level `概ね対応 / 詳細未確認` evidence
- MUST NOT convert unknown child tasks to completed or failed
- closes the fine-grained reconciliation nag only as canonical specifies
- UI after action should explain that child results remain unknown where applicable

### 5.3 個別で答える

Normal case per row:

```text
洗濯                         [完了]
                              その他の結果
```

Keep exceptions behind `その他の結果`:

- 相手が対応
- できなかった
- 今回は不要
- 中止になった
- 別の日にやる（再予定）

Do not expose every rare state as equal-weight permanent buttons.

## 6. Actual date/time UX

Canonical rule remains:

- users do **not** manage exact actual completion time as a normal field
- registration / correction timestamps are audit data
- if yesterday's work is entered the next morning, bind actual outcome to the original task/occurrence target date
- ask only when target date is genuinely ambiguous

History normal view should therefore look like:

```text
予定: 9/5 19:00 · パパ
実績: 9/5 · パパ
```

not as if audit timestamp were the semantic completion time.

Audit details may expose:

```text
登録日時: 9/5 20:31
訂正履歴: ...
```

behind a secondary/details surface.

## 7. Completed vs unknown

Never treat no input as `できなかった`.

UI and model must preserve distinction between at least:

- completed
- unknown / not entered
- partner handled
- could not do
- not needed this occurrence
- cancelled / no longer needed
- rescheduled

`大体やった` is group reconciliation evidence, not an extra child-task lifecycle status.

## 8. Concierge placement

`おうちコンシェルジュ` remains:

- text free input
- voice → transcription → same semantic AI layer
- multi-intent candidate generation
- shared household terminology/context
- same authority/safety/canonical command layer as LINE

But its product role is:

> 予定外の入力を分類せずに入れられる万能入口

It MUST NOT replace Today as the answer to `今なにをすればいい？`.

## 9. CURRENT implementation mapping

Implementation owner should reuse CURRENT components/business contracts rather than rewriting them from prototype code.

### `apps/web/src/features/today/Today.tsx`

- keep Today as operational aggregation page
- preserve pending decision, schedule, next action, tomorrow, routine, shopping and partner-critical behavior
- change/add current-work sections so exact aggregate scope is visible before aggregate actual actions
- maintain Q87 evening collapse behavior

### `apps/web/src/features/checkin/CheckinPage.tsx`

CURRENT already has:

- `全部やった`
- `大体やった`
- `個別で答える`
- per-item completion
- subtask mutation
- `相手が対応`
- `今回は不要`

Required UX refinement:

- render exact included items before group reconciliation controls
- scope aggregate labels (`この2件を全部やった` etc.)
- implement/render missing canonical individual exception outcomes rather than collapsing all non-completion to current limited choices
- after aggregate completion, provide undo/correction path without redundant pre-confirmation

Do not bypass existing edge/RPC commands, revision/CAS or authorization rules merely to match the prototype.

### `apps/web/src/features/history/HistoryPage.tsx`

CURRENT uses `completed_at` in the normal `実績:` line. Review/adjust presentation so audit timestamp is not presented as user-managed semantic actual time, while preserving underlying audit data and correction history.

### Quick Add / Concierge

- preserve explicit Quick Add operations
- add concierge at top
- shared semantic AI layer with LINE, not a duplicated PWA-only parser

## 10. Implementation contract vs prototype

The companion HTML prototype is a **UI/interaction contract**, not production source.

Implementation should match, unless a documented canonical conflict is found:

- information hierarchy
- visible scope before aggregate actions
- button wording / normal-vs-exception weighting
- Today-first flow
- daypart behavior
- correction/undo placement
- history semantic-time presentation
- concierge role and placement

Implementation must reuse CURRENT production-grade behavior for:

- auth
- Supabase/RLS
- edge functions / RPC
- request state machines
- revision/CAS
- idempotency
- realtime refresh
- LINE/provider authority
- Google authority
- external side-effect fences

Do not replace those with prototype-local state.

## 11. Acceptance scenarios

1. Evening with two unfinished normal chores: Today names both before showing aggregate completion.
2. User can complete one row directly from Today without navigating to a separate history/actual form.
3. Aggregate completion clearly means only the currently displayed group.
4. Completed morning tasks at night render as `朝 n/n完了`, not a repeated checklist.
5. Morning problem/unfinished item remains concrete even in evening.
6. `大体やった` does not inflate completed count or failed count.
7. Individual normal completion is one tap; exceptions are behind secondary disclosure.
8. Next-morning entry attaches to original target date, not entry date.
9. Normal History does not imply audit timestamp is user-entered actual time.
10. Concierge does not dominate or replace current-action information on Today.
11. Same natural-language content through LINE / PWA concierge reaches the shared semantic interpretation and produces semantically equivalent candidates.
12. Every mutation continues to obey canonical authority, revision/CAS, idempotency and household isolation.
