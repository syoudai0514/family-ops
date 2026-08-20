# 05. AI / Gemini

## 1. 役割

Geminiは補助機能。DB更新のauthorityではない。

用途:
1. natural language intent分類
2. task/request/shopping/calendar fields抽出
3. partner向け文章の柔らかい言い換え
4. handoverの要点化

## 2. AIを通さない操作

- 完了ボタン
- request accept/decline
- shopping status transition
- recurring rule設定画面
- PWA formの明示フィールド

これらはdeterministic。

## 3. 無料枠方針

MVP設定:
`AI_MODE=free_lightweight`

意味:
- 軽い家庭ToDo・依頼・買い物・予定の自然文処理に使う。
- secret/金融/医療記録/正確な住所等はAIに送らない。
- userがAIをOFFにしても全機能を手動で使える。

将来:
- `disabled`
- `free_lightweight`
- `paid`
を切替可能な構造にするが、MVP UIは`AI ON/OFF`でよい。

## 4. Partner rewrite contract

入力:
- private raw text
- requested task facts

出力JSON:
```json
{
  "shared_message": "...",
  "facts": {
    "action": "牛乳を買う",
    "due": null,
    "quantity": null,
    "target": "partner"
  },
  "warnings": []
}
```

禁止:
- 「ありがとう」「ごめん」を勝手に追加
- requesterの感情を捏造
- 数量変更
- 期限変更
- 否定/肯定反転
- 依頼対象の変更
- 元の要求を強くする

## 5. Two-pass validation

1. model rewrite
2. deterministic comparison
   - extracted action
   - due
   - quantity
   - negation
3. mismatchならpreviewにwarningしてauto-send不可

必要に応じてcheap modelで2nd checkしてよいが、MVPはdeterministic first。

## 6. Intent schema

```ts
type ParsedIntent =
 | {type:'task.create'; title:string; due?:string; assignee?:'self'|'partner'|'unassigned'}
 | {type:'task.complete'; targetHint:string}
 | {type:'recurrence.change'; taskCode:string; weekday:number; assignee:'self'|'partner'; scope:'once'|'future'|'ambiguous'}
 | {type:'request.create'; title:string; message:string; due?:string}
 | {type:'shopping.add'; title:string; method?:'store'|'online'|'either'|'undecided'}
 | {type:'handover.create'; text:string; period?:string; categories?:string[]}
 | {type:'calendar.create'; title:string; startsAt?:string; endsAt?:string}
 | {type:'unknown'}
```

`weekday` はISO Monday=1 ... Sunday=7。

## 7. Pending action

AI parse結果を直接実行しない。

`parse -> pending_action -> preview -> confirm -> durable execution worker -> atomic business transition`

明らかな安全操作（例: Bot replyで今届いた1件のrequestをaccept）は明示button actionとしてAI不要。

## 8. Fallback

AI unavailable:
- PWA: formに切替
- LINE: structured quick repliesで最低限登録

絶対禁止:
`AI失敗 -> raw textをpartnerへ送る`

## 9. Golden fixtures

`fixtures/AI_GOLDEN_FIXTURES.json` を30件以上維持。

含める:
- normal request
- rude/感情的文のsoft rewrite
- quantity/date preservation
- recurrence once/future ambiguity
- shopping
- handover
- calendar
- no-op/unknown
- secret-like input rejected
- exact address/phone/email guard
- prompt injection風入力
