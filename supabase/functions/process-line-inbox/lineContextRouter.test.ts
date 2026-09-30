import { assertEquals } from "jsr:@std/assert@1";
import {
  buildRouterPrompt,
  guardDecision,
  parseRouterDecision,
  routeLineText,
  runRouterDecision,
  type RouterContext,
  type RouterEffects,
} from "./lineContextRouter.ts";
import { isFixedShortcutText } from "./lineConversation.ts";
import { jstClock } from "./lineRouterWiring.ts";
import { buildShoppingListReply } from "./lineShoppingList.ts";

const baseContext = (over: Partial<RouterContext> = {}): RouterContext => ({
  now: { date: "2026-09-30", time: "22:27", weekday: "水" },
  me: "パパ",
  partner: "ママ",
  turns: [],
  pendingDraft: null,
  shopping: [
    { title: "将生用のしろい無地のTシャツを買う", who: null },
    { title: "牛乳", who: "me" },
    { title: "角ウイスキー", who: "partner" },
  ],
  myTasks: ["詩乃の薬・便の記録", "送り"],
  partnerOpenCount: 8,
  ...over,
});

Deno.test("prompt: the conversation, the pending draft and the household reach the model", () => {
  const ctx = baseContext({
    turns: [
      { role: "user", text: "買うものは？" },
      { role: "assistant", text: "どなたが何を買う予定か教えていただけますか？" },
    ],
    pendingDraft: { kind: "task_create", title: "牛乳を買う" },
  });
  const prompt = buildRouterPrompt(ctx, "おれ");
  // The bot's own previous question is what "おれ" answers.
  assertEquals(prompt.includes("どなたが何を買う予定か教えていただけますか？"), true);
  assertEquals(prompt.includes('"speaker":"おうちノート"'), true);
  assertEquals(prompt.includes('"speaker":"パパ(ユーザー)"'), true);
  // The current message is separate from the history.
  assertEquals(prompt.endsWith('"おれ"'), true);
  assertEquals(prompt.includes("牛乳を買う"), true);
  assertEquals(prompt.includes("将生用のしろい無地のTシャツを買う"), true);
  assertEquals(prompt.includes("詩乃の薬・便の記録"), true);
  assertEquals(prompt.includes("2026-09-30(水) 22:27"), true);
});

Deno.test("prompt: only the last ten turns are sent, each clipped", () => {
  const turns = Array.from({ length: 14 }, (_, i) => ({ role: "user" as const, text: `発言${i}` + "あ".repeat(400) }));
  const prompt = buildRouterPrompt(baseContext({ turns }), "x");
  assertEquals(prompt.includes("発言3あ"), false);
  assertEquals(prompt.includes("発言4あ"), true);
  assertEquals(prompt.includes("あ".repeat(400)), false);
});

Deno.test("parse: a valid decision, fenced JSON, and everything unusable", () => {
  assertEquals(parseRouterDecision('{"action":"shopping_list","confidence":"high","who":"me"}'), {
    action: "shopping_list", confidence: "high", who: "me",
  });
  assertEquals(parseRouterDecision('```json\n{"action":"answer","confidence":"medium","reply":"こんにちは"}\n```')?.reply, "こんにちは");
  assertEquals(parseRouterDecision('{"action":"purchase","confidence":"high","hint":" Tシャツ ","all":false}'), {
    action: "purchase", confidence: "high", hint: "Tシャツ",
  });
  for (const bad of ["", "not json", "[]", '{"action":"delete_everything"}', '{"confidence":"high"}', "null"]) {
    assertEquals(parseRouterDecision(bad), null, bad);
  }
  assertEquals(parseRouterDecision('{"action":"pass"}')?.confidence, "low");
});

Deno.test("guard: a recording action on a hunch becomes a question, or falls back", () => {
  const ctx = baseContext();
  assertEquals(guardDecision({ action: "purchase", confidence: "low", reply: "どれを買いましたか？" }, ctx), {
    action: "clarify", confidence: "low", reply: "どれを買いましたか？",
  });
  assertEquals(guardDecision({ action: "create", confidence: "low", text: "牛乳" }, ctx), null);
  assertEquals(guardDecision({ action: "purchase", confidence: "high", hint: "牛乳" }, ctx)?.action, "purchase");
  // Reading is always safe, even at low confidence.
  assertEquals(guardDecision({ action: "shopping_list", confidence: "low" }, ctx)?.who, "any");
});

Deno.test("guard: replies may not claim something was done; drafts need a draft; create needs text", () => {
  const ctx = baseContext();
  assertEquals(guardDecision({ action: "answer", confidence: "high", reply: "ママにお願いを送りました" }, ctx), null);
  assertEquals(guardDecision({ action: "answer", confidence: "high" }, ctx), null);
  assertEquals(guardDecision({ action: "answer", confidence: "high", reply: "牛乳が1件です" }, ctx)?.action, "answer");
  assertEquals(guardDecision({ action: "cancel_draft", confidence: "high" }, ctx), null);
  assertEquals(guardDecision({ action: "cancel_draft", confidence: "high" }, baseContext({ pendingDraft: { kind: "k", title: "t" } }))?.action, "cancel_draft");
  assertEquals(guardDecision({ action: "create", confidence: "high" }, ctx), null);
  assertEquals(guardDecision({ action: "schedule", confidence: "high" }, ctx)?.range, "today");
});

function fakeEffects() {
  const calls: string[] = [];
  const effects: RouterEffects = {
    showShoppingList: (who) => { calls.push(`list:${who}`); return Promise.resolve(); },
    showSchedule: (range) => { calls.push(`schedule:${range}`); return Promise.resolve(); },
    purchase: (report) => { calls.push(`purchase:${report.hint}:${report.all}`); return Promise.resolve(); },
    done: (text) => { calls.push(`done:${text}`); return Promise.resolve(text.includes("洗濯")); },
    reply: (text) => { calls.push(`reply:${text}`); return Promise.resolve(); },
    cancelDraft: () => { calls.push("cancel"); return Promise.resolve(); },
  };
  return { calls, effects };
}

// The live conversation of 2026-09-30 22:27-22:29, replayed. The scripted model only
// answers correctly when the prompt actually carries the conversation -- which is the
// point: it did not, so the old code could not.
Deno.test("live conversation: each message is understood in the light of the ones before it", async () => {
  const turns: RouterContext["turns"] = [];
  const say = (role: "user" | "assistant", text: string) => turns.push({ role, text });
  const provider = (script: (prompt: string) => string) => (prompt: string) => Promise.resolve(script(prompt));

  // 1. "買うものは？" -> the shopping list. (Previously: a clarifying question.)
  {
    const { calls, effects } = fakeEffects();
    const decision = await routeLineText(baseContext({ turns: [...turns] }), "買うものは？",
      provider(() => '{"action":"shopping_list","confidence":"high","who":"any"}'));
    assertEquals((await runRouterDecision(decision!, effects, "買うものは？")).handled, true);
    assertEquals(calls, ["list:any"]);
    say("user", "買うものは？");
    say("assistant", "買い物リスト（1件）\n・将生用のしろい無地のTシャツを買う");
  }

  // 2. "おれ" right after the bot asked "どなたが…？": the model must SEE that question.
  {
    const asked = [...turns, { role: "assistant" as const, text: "どなたの分の買い物リストを見ますか？（パパ／ママ／担当なし）" }];
    const { calls, effects } = fakeEffects();
    const decision = await routeLineText(baseContext({ turns: asked }), "おれ",
      provider((prompt) => prompt.includes("どなたの分の買い物リストを見ますか？")
        ? '{"action":"shopping_list","confidence":"high","who":"me"}'
        : '{"action":"answer","confidence":"low","reply":"「おれ」について、何かお困りごとがありますか？"}'));
    await runRouterDecision(decision!, effects, "おれ");
    assertEquals(calls, ["list:me"]);
  }

  // 3. "間違えた。俺が買うべきもの" is a re-statement, not a cancellation.
  {
    const { calls, effects } = fakeEffects();
    const decision = await routeLineText(baseContext({ turns: [...turns, { role: "user", text: "俺が買いたいもの" }] }), "間違えた。俺が買うべきもの",
      provider((prompt) => prompt.includes("俺が買いたいもの")
        ? '{"action":"shopping_list","confidence":"high","who":"me"}'
        : '{"action":"cancel_draft","confidence":"high"}'));
    await runRouterDecision(decision!, effects, "間違えた。俺が買うべきもの");
    assertEquals(calls, ["list:me"]);
  }

  // 4. "いや、買うべきもの教えてよ": still the list -- never "さきほどの入力は取り消し済み".
  {
    const { calls, effects } = fakeEffects();
    const decision = await routeLineText(baseContext({ turns: [...turns] }), "いや、買うべきもの教えてよ",
      provider(() => '{"action":"shopping_list","confidence":"high","who":"me"}'));
    await runRouterDecision(decision!, effects, "いや、買うべきもの教えてよ");
    assertEquals(calls, ["list:me"]);
  }

  // 5. And the message that started the day: "買ったよ" after the list -> a purchase, not a draft.
  {
    const { calls, effects } = fakeEffects();
    const decision = await routeLineText(baseContext({ turns: [...turns] }), "買ったよ",
      provider(() => '{"action":"purchase","confidence":"high","hint":null,"all":false}'));
    await runRouterDecision(decision!, effects, "買ったよ");
    assertEquals(calls, ["purchase:null:false"]);
  }
});

Deno.test("routing: create hands back the resolved text; unmatched done and pass fall through", async () => {
  const { calls, effects } = fakeEffects();
  assertEquals(await runRouterDecision({ action: "create", confidence: "high", text: "明日の朝、ゴミ出しをママにお願い" }, effects, "それお願い"),
    { handled: false, createText: "明日の朝、ゴミ出しをママにお願い" });
  assertEquals(await runRouterDecision({ action: "done", confidence: "high", text: "掃除した" }, effects, "掃除終わった"), { handled: false });
  assertEquals(await runRouterDecision({ action: "done", confidence: "high", text: "洗濯した" }, effects, "洗濯終わった"), { handled: true });
  assertEquals(await runRouterDecision({ action: "pass", confidence: "high" }, effects, "x"), { handled: false });
  assertEquals(await runRouterDecision({ action: "clarify", confidence: "medium", reply: "どっちですか？" }, effects, "x"), { handled: true });
  assertEquals(calls, ["done:掃除した", "done:洗濯した", "reply:どっちですか？"]);
});

Deno.test("routing: an unavailable or unusable model falls back to the old handlers (null)", async () => {
  assertEquals(await routeLineText(baseContext(), "x", () => Promise.resolve(null)), null);
  assertEquals(await routeLineText(baseContext(), "x", () => Promise.resolve("こんにちは")), null);
  assertEquals(await routeLineText(baseContext(), "x", () => Promise.resolve('{"action":"answer","confidence":"high","reply":"登録しました"}')), null);
});

Deno.test("fixed shortcuts never go through the model", () => {
  for (const t of ["今日", "明日", "今週", "入力", "追加", "共有", "その他", "メニュー", "今日？", "予定を追加したい", "買い物を追加したい", "お願いを送りたい"]) {
    assertEquals(isFixedShortcutText(t), true, t);
  }
  for (const t of ["買うものは？", "おれ", "今日なんか予定あったっけ？", "牛乳買って", "いや、買うべきもの教えてよ"]) {
    assertEquals(isFixedShortcutText(t), false, t);
  }
});

Deno.test("clock: JST date, time and weekday", () => {
  assertEquals(jstClock(new Date("2026-09-30T13:29:00Z")), { date: "2026-09-30", time: "22:29", weekday: "水" });
  assertEquals(jstClock(new Date("2026-09-30T15:05:00Z")), { date: "2026-10-01", time: "00:05", weekday: "木" });
});

Deno.test("shopping list: filters by who", () => {
  const rows = [
    { title: "Tシャツ", status: "wanted", assignee_id: null },
    { title: "牛乳", status: "assigned", assignee_id: "papa" },
    { title: "ウイスキー", status: "assigned", assignee_id: "mama" },
  ];
  const roles = new Map([["papa", "パパ"], ["mama", "ママ"]]);
  assertEquals(buildShoppingListReply(rows, { actorId: "papa", roles, who: "me" }), "あなたが買うもの（担当なしを含む）（2件）\n・Tシャツ\n・牛乳");
  assertEquals(buildShoppingListReply(rows, { actorId: "papa", roles, who: "partner" }), "ママが買うもの（1件）\n・ウイスキー");
  assertEquals(buildShoppingListReply(rows, { actorId: "papa", roles, who: "unassigned" }), "担当が決まっていない買い物（1件）\n・Tシャツ");
  assertEquals(buildShoppingListReply(rows, { actorId: "papa", roles, who: "partner" }).includes("パパ"), false);
  assertEquals(buildShoppingListReply([], { actorId: "papa", roles, who: "me" }), "あなたが買うもの（担当なしを含む）は、いまありません。");
});
