import { assertEquals } from "jsr:@std/assert@1";
import {
  buildUnderstandPrompt,
  evaluateUnderstanding,
  guardPlan,
  parsePlan,
  type Plan,
  type PlanEffects,
  runPlan,
  type Snapshot,
  understandLineText,
} from "./lineUnderstand.ts";
import { isFixedShortcutText } from "./lineConversation.ts";
import { jstClock } from "./lineRouterWiring.ts";
import { buildShoppingListReply } from "./lineShoppingList.ts";

const snap = (over: Partial<Snapshot> = {}): Snapshot => ({
  now: { date: "2026-09-30", time: "22:27", weekday: "水" },
  me: "パパ",
  partner: "ママ",
  children: [{ name: "将生", school: "保育園", className: "すだち組" }],
  turns: [],
  pendingDraft: null,
  tasks: [
    { ref: "t1", id: "uuid-t1", title: "お迎え", who: "partner", due: "18:20", status: "todo", code: "pickup" },
    { ref: "t2", id: "uuid-t2", title: "洗濯", who: "me", due: null, status: "todo", code: null },
    { ref: "t3", id: "uuid-t3", title: "コドモン送信", who: "me", due: "09:15", status: "todo", code: "codmon_submit" },
  ],
  shopping: [
    { ref: "s1", id: "uuid-s1", title: "将生用のしろい無地のTシャツを買う", who: null, revision: 2 },
    { ref: "s2", id: "uuid-s2", title: "牛乳", who: "me", revision: 1 },
  ],
  sharedNotes: ["【言語通級】"],
  ...over,
});

Deno.test("prompt: conversation (both sides), draft, tasks, shopping, children and clock reach the model", () => {
  const p = buildUnderstandPrompt(snap({
    turns: [{ role: "user", text: "買うものは？" }, { role: "assistant", text: "どなたの分を見ますか？" }],
    pendingDraft: { kind: "task_create_once", title: "牛乳を買う" },
  }), "おれ");
  for (const needle of [
    "パパ: 買うものは？", "おうちノート: どなたの分を見ますか？", "パパ: おれ",
    "牛乳を買う", '"ref":"s1"', "将生用のしろい無地のTシャツを買う", '"ref":"t1"', "お迎え", "18:20",
    "将生（保育園・すだち組）", "2026-09-30(水) 22:27", "【言語通級】",
  ]) assertEquals(p.includes(needle), true, needle);
  // Internal ids never reach the model; it only sees refs.
  assertEquals(p.includes("uuid-"), false);
  // The new message comes last, after the history.
  assertEquals(p.trimEnd().endsWith("パパ: おれ"), true);
});

Deno.test("parse: a full plan; unknown actions and junk are rejected", () => {
  const plan = parsePlan('{"understanding":"自分の買い物","reply":"パパが買うものはこれ👇","actions":[{"type":"show_shopping","who":"me"}],"confidence":"high"}');
  assertEquals(plan, { understanding: "自分の買い物", reply: "パパが買うものはこれ👇", actions: [{ type: "show_shopping", who: "me" }], confidence: "high" });
  assertEquals(parsePlan('```json\n{"reply":"はい","actions":[]}\n```')?.confidence, "low");
  for (const bad of ["", "x", "[]", '{"reply":"","actions":[]}', '{"reply":"ok","actions":[{"type":"delete_all"}]}', '{"actions":[{"type":"mark_bought","refs":[]}]}']) {
    assertEquals(parsePlan(bad), null, bad);
  }
});

Deno.test("guard: refs must exist; a request that leaves nothing valid falls back", () => {
  const s = snap();
  const p = (actions: Plan["actions"], extra: Partial<Plan> = {}): Plan => ({ understanding: "", reply: "了解！", actions, confidence: "high", ...extra });
  assertEquals(guardPlan(p([{ type: "mark_bought", refs: ["s9", "s2", "s2"] }]), s)?.actions, [{ type: "mark_bought", refs: ["s2"] }]);
  assertEquals(guardPlan(p([{ type: "complete_task", ref: "t99", by: "self" }]), s), null);
  assertEquals(guardPlan(p([{ type: "cancel_draft" }]), s), null); // no draft
  assertEquals(guardPlan(p([{ type: "cancel_draft" }]), snap({ pendingDraft: { kind: "k", title: "x" } }))?.actions.length, 1);
});

Deno.test("guard: no lies, no records on a hunch", () => {
  const s = snap();
  // A reply claiming a record with no action is a lie -> fallback.
  assertEquals(guardPlan({ understanding: "", reply: "ママにお願いを送りました", actions: [], confidence: "high" }, s), null);
  // With a real record, a claiming lead is dropped; the handler prints the true outcome.
  assertEquals(guardPlan({ understanding: "", reply: "登録しました！", actions: [{ type: "mark_bought", refs: ["s1"] }], confidence: "high" }, s)?.reply, "");
  // Low confidence + record -> only the question is sent.
  assertEquals(guardPlan({ understanding: "", reply: "どれを買ったの？", actions: [{ type: "mark_bought", refs: ["s1"] }], confidence: "low" }, s),
    { understanding: "", reply: "どれを買ったの？", actions: [], confidence: "low" });
  // Reading stays allowed at low confidence.
  assertEquals(guardPlan({ understanding: "", reply: "これだよ", actions: [{ type: "show_shopping", who: "me" }], confidence: "low" }, s)?.actions.length, 1);
});

function fakeEffects() {
  const log: string[] = [];
  const effects: PlanEffects = {
    showShopping: (who) => { log.push(`list:${who}`); return Promise.resolve([{ text: `LIST(${who})` }]); },
    markBought: (items) => { log.push(`bought:${items.map((i) => i.id).join(",")}`); return Promise.resolve([{ text: "✓ 買った", quick: ["undo-buy"] }]); },
    completeTask: (task, by, codes) => { log.push(`done:${task.id}:${by}${codes?.length ? `:${codes.join("+")}` : ""}`); return Promise.resolve([{ text: `✓ ${task.title}`, quick: ["undo-task"] }]); },
    cancelDraft: () => { log.push("cancel"); return Promise.resolve([{ text: "✓ 取り消し" }]); },
    showSchedule: (range, lead) => { log.push(`schedule:${range}:${lead}`); return Promise.resolve(); },
    send: (text, quick) => { log.push(`SEND:${text}|${JSON.stringify(quick ?? null)}`); return Promise.resolve(); },
  };
  return { log, effects };
}

Deno.test("run: several results go out as ONE reply (one free LINE reply per message)", async () => {
  const { log, effects } = fakeEffects();
  const out = await runPlan({
    understanding: "", reply: "おつかれさま！", confidence: "high",
    actions: [{ type: "complete_task", ref: "t2", by: "self" }, { type: "mark_bought", refs: ["s2"] }],
  }, snap(), effects, "洗濯終わった、牛乳も買った");
  assertEquals(out, { done: true });
  assertEquals(log, ["done:uuid-t2:self", "bought:uuid-s2", 'SEND:おつかれさま！\n\n✓ 洗濯\n\n✓ 買った|["undo-buy"]']);
});

Deno.test("run: the list follows the model's own lead line; a partner's chore is recorded as theirs", async () => {
  const a = fakeEffects();
  await runPlan({ understanding: "", reply: "パパが買うものはこれ👇", confidence: "high", actions: [{ type: "show_shopping", who: "me" }] }, snap(), a.effects, "おれ");
  assertEquals(a.log, ["list:me", "SEND:パパが買うものはこれ👇\n\nLIST(me)|null"]);
  const b = fakeEffects();
  await runPlan({ understanding: "", reply: "", confidence: "high", actions: [{ type: "complete_task", ref: "t1", by: "partner" }] }, snap(), b.effects, "ママがお迎え行ってくれた");
  assertEquals(b.log[0], "done:uuid-t1:partner");
});

Deno.test("run: schedule carries the lead; create/edit/legacy hand back to the caller", async () => {
  const a = fakeEffects();
  assertEquals(await runPlan({ understanding: "", reply: "今日はこんな感じ👇", confidence: "high", actions: [{ type: "show_schedule", range: "today" }] }, snap(), a.effects, "今日なんかある？"), { done: true });
  assertEquals(a.log, ["schedule:today:今日はこんな感じ👇"]);
  const b = fakeEffects();
  assertEquals(await runPlan({ understanding: "", reply: "了解！", confidence: "high", actions: [{ type: "create", text: "明日の朝、ゴミ出しをママにお願い" }] }, snap(), b.effects, "それママにお願い"),
    { done: false, continueWith: { text: "明日の朝、ゴミ出しをママにお願い", mode: "create" }, pendingReply: "" });
  assertEquals(b.log, []);
  const c = fakeEffects();
  const out = await runPlan({ understanding: "", reply: "ありがとう", confidence: "high", actions: [{ type: "mark_bought", refs: ["s2"] }, { type: "create", text: "パンを買う" }] }, snap(), c.effects, "牛乳買った、パン買っといて");
  assertEquals(out, { done: false, continueWith: { text: "パンを買う", mode: "create" }, pendingReply: "ありがとう\n\n✓ 買った" });
  const d = fakeEffects();
  assertEquals(await runPlan({ understanding: "", reply: "", confidence: "high", actions: [{ type: "legacy" }] }, snap(), d.effects, "今週のお迎え代わって"),
    { done: false, continueWith: { text: "今週のお迎え代わって", mode: "legacy" }, pendingReply: "" });
});

// The live conversation of 2026-09-30 22:27-22:29. The scripted model answers correctly
// only when the prompt carries what came before -- which the old code never sent.
Deno.test("live conversation replay: answers depend on the context actually reaching the model", async () => {
  const model = (prompt: string) => {
    if (prompt.includes("パパ: おれ") && prompt.includes("おうちノート: どなたの分")) {
      return Promise.resolve('{"understanding":"自分の分","reply":"パパが買うものはこれ👇","actions":[{"type":"show_shopping","who":"me"}],"confidence":"high"}');
    }
    return Promise.resolve('{"understanding":"不明","reply":"「おれ」について、何かお困りごとがありますか？","actions":[],"confidence":"low"}');
  };
  const withContext = await understandLineText(snap({ turns: [{ role: "user", text: "買うものは？" }, { role: "assistant", text: "どなたの分を見ますか？" }] }), "おれ", model);
  assertEquals(withContext.plan?.actions, [{ type: "show_shopping", who: "me" }]);
  const without = await understandLineText(snap(), "おれ", model);
  assertEquals(without.plan?.actions, []);
});

Deno.test("unavailable or unusable model -> null plan (the old handlers take over)", async () => {
  assertEquals((await understandLineText(snap(), "x", () => Promise.resolve(null))).plan, null);
  assertEquals((await understandLineText(snap(), "x", () => Promise.resolve("こんにちは"))).plan, null);
  assertEquals((await understandLineText(snap(), "x", () => Promise.resolve('{"reply":"登録しました","actions":[]}'))).plan, null);
});

Deno.test("evaluation endpoint: builds snapshots from the request, touches nothing else", async () => {
  const seen: string[] = [];
  const res = await evaluateUnderstanding([
    { id: "a", message: "買うものは？", snapshot: { shopping: [{ title: "牛乳", who: "me" }], turns: [{ role: "assistant", text: "こんばんは" }] } },
  ], (prompt) => { seen.push(prompt); return Promise.resolve('{"reply":"これ👇","actions":[{"type":"show_shopping","who":"any"}],"confidence":"high"}'); });
  assertEquals(res.results[0].plan?.actions, [{ type: "show_shopping", who: "any" }]);
  assertEquals(seen[0].includes('"ref":"s1","品物":"牛乳"'), true);
  assertEquals(seen[0].includes("おうちノート: こんばんは"), true);
});

Deno.test("fixed button words never go through the model", () => {
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
  assertEquals(buildShoppingListReply([], { actorId: "papa", roles, who: "me" }), "あなたが買うもの（担当なしを含む）は、いまありません。");
});

// Production evaluation 2026-09-30: for "コドモン送りました。朝食はやってあった" the real
// model completed the submit AND the breakfast input separately; the second would fail
// as already done (the submit closes all inputs). It is folded into the submit instead.
Deno.test("run: Codmon inputs the model lists are folded into the submit as partner codes", async () => {
  const s = snap({ tasks: [
    { ref: "t1", id: "uuid-submit", title: "コドモン送信", who: "me", due: "09:15", status: "todo", code: "codmon_submit" },
    { ref: "t2", id: "uuid-bf", title: "詩乃：コドモン入力（朝食）", who: "partner", due: null, status: "todo", code: "codmon_shino_breakfast_input" },
    { ref: "t3", id: "uuid-prev", title: "詩乃：コドモン入力（昨日の夕飯）", who: "me", due: null, status: "todo", code: "codmon_shino_previous_input" },
  ] });
  const { log, effects } = fakeEffects();
  await runPlan({ understanding: "", reply: "おつかれさま！", confidence: "high", actions: [
    { type: "complete_task", ref: "t1", by: "self" },
    { type: "complete_task", ref: "t2", by: "partner" },
    { type: "complete_task", ref: "t3", by: "self" },
  ] }, s, effects, "コドモン送りました。朝食はやってあった");
  assertEquals(log, ["done:uuid-submit:self:codmon_shino_breakfast_input", 'SEND:おつかれさま！\n\n✓ コドモン送信|["undo-task"]']);
  // Without the submit, an input is completed on its own as usual.
  const b = fakeEffects();
  await runPlan({ understanding: "", reply: "", confidence: "high", actions: [{ type: "complete_task", ref: "t2", by: "partner" }] }, s, b.effects, "朝食の入力はママがやった");
  assertEquals(b.log[0], "done:uuid-bf:partner");
});
