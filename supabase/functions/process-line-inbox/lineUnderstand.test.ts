import { assertEquals } from "jsr:@std/assert@1";
import {
  buildUnderstandPrompt,
  draftToPending,
  evaluateUnderstanding,
  guardPlan,
  makeGeminiProvider,
  UNDERSTAND_ATTEMPT_TIMEOUT_MS,
  understandAttempts,
  parseDraft,
  parsePlan,
  type Plan,
  resolveUnderstandModel,
  type PlanEffects,
  runPlan,
  type Snapshot,
  understandLineText,
} from "./lineUnderstand.ts";
import { geminiGenerationConfig } from "../_shared/gemini.ts";
import { isFixedShortcutText } from "./lineConversation.ts";
import { describePendingDraft, jstClock } from "./lineRouterWiring.ts";
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
  assertEquals(log, ["done:uuid-t2:self", "bought:uuid-s2", 'SEND:おつかれさま！\n\n✓ 洗濯\n✓ 買った|["undo-buy"]']);
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

Deno.test("budget: no call when the minute is used up; no retry on 429; one retry on a 5xx", async () => {
  const env = Deno.env.get("GEMINI_MODEL_LINE_UNDERSTAND");
  Deno.env.set("GEMINI_MODEL_LINE_UNDERSTAND", "test-model");
  const realFetch = globalThis.fetch;
  const realKey = Deno.env.get("GEMINI_API_KEY");
  Deno.env.set("GEMINI_API_KEY", "k");
  try {
    let calls = 0;
    const answers: number[] = [];
    globalThis.fetch = (() => {
      calls++;
      const status = answers.shift() ?? 200;
      return Promise.resolve(new Response(
        status === 200 ? JSON.stringify({ candidates: [{ content: { parts: [{ text: '{"reply":"ok","actions":[]}' }] } }] }) : "{}",
        { status },
      ));
    }) as typeof fetch;

    // Budget says no -> the model is not called at all.
    assertEquals(await makeGeminiProvider(() => Promise.resolve(false))("p"), null);
    assertEquals(calls, 0);

    // 429 -> no second request in the same minute.
    answers.push(429);
    assertEquals(await makeGeminiProvider(() => Promise.resolve(true))("p"), null);
    assertEquals(calls, 1);

    // 503 then 200 -> one retry, and the retry asked the budget too.
    calls = 0;
    let asked = 0;
    answers.push(503, 200);
    assertEquals(await makeGeminiProvider(() => { asked++; return Promise.resolve(true); })("p"), '{"reply":"ok","actions":[]}');
    assertEquals([calls, asked], [2, 2]);
  } finally {
    globalThis.fetch = realFetch;
    if (env === undefined) Deno.env.delete("GEMINI_MODEL_LINE_UNDERSTAND"); else Deno.env.set("GEMINI_MODEL_LINE_UNDERSTAND", env);
    if (realKey === undefined) Deno.env.delete("GEMINI_API_KEY"); else Deno.env.set("GEMINI_API_KEY", realKey);
  }
});

Deno.test("provider: a slow or busy model retries once on the environment model, with low thinking and a timeout", async () => {
  const env = Deno.env.get("GEMINI_MODEL_LINE_UNDERSTAND");
  Deno.env.set("GEMINI_MODEL_LINE_UNDERSTAND", "gemini-3.1-flash-lite");
  try {
    const seen: Array<{ model: string; timeoutMs?: number; thinkingLevel?: string }> = [];
    const call = (_prompt: string, model: string, options: { timeoutMs?: number; thinkingLevel?: string } = {}) => {
      seen.push({ model, ...options });
      return seen.length === 1 ? Promise.reject(new Error("GEMINI_TIMEOUT")) : Promise.resolve('{"reply":"ok","actions":[]}');
    };
    const provider = makeGeminiProvider(() => Promise.resolve(true), "gemini-3.5-flash", undefined, call);
    assertEquals(await provider("p"), '{"reply":"ok","actions":[]}');
    assertEquals(seen.map((s) => s.model), ["gemini-3.5-flash", "gemini-3.1-flash-lite"]);
    assertEquals(seen.every((s) => s.timeoutMs === UNDERSTAND_ATTEMPT_TIMEOUT_MS && s.thinkingLevel === "low"), true);
    assertEquals(understandAttempts(null).map((a) => a.model), ["gemini-3.1-flash-lite", "gemini-3.1-flash-lite"]);
  } finally {
    if (env === undefined) Deno.env.delete("GEMINI_MODEL_LINE_UNDERSTAND"); else Deno.env.set("GEMINI_MODEL_LINE_UNDERSTAND", env);
  }
});

Deno.test("gemini request: thinking level is sent only to Gemini 3 models", () => {
  assertEquals(geminiGenerationConfig("gemini-3.5-flash", { thinkingLevel: "low" }).thinkingConfig, { thinkingLevel: "low" });
  assertEquals(geminiGenerationConfig("gemini-2.5-flash", { thinkingLevel: "low" }).thinkingConfig, undefined);
  assertEquals(geminiGenerationConfig("gemini-3.5-flash").thinkingConfig, undefined);
});

Deno.test("evaluation: at most 5 cases per request", async () => {
  let n = 0;
  const cases = Array.from({ length: 9 }, (_, i) => ({ id: i, message: "x" }));
  const res = await evaluateUnderstanding(cases, () => { n++; return Promise.resolve('{"reply":"ok","actions":[]}'); });
  assertEquals([res.results.length, n], [5, 5]);
});

// Live 2026-09-30 23:17-23:18: "明日、将生の保育園に下着2こ持っていかないと。入れといて" then
// "将生のね。あと朝だから朝担当の人でよろしくね". The model understood both, but only a
// sentence was handed on and a second parse dropped the child, the count, the morning and
// the person. The model's filled-in draft now goes into the card as it is.
Deno.test("draft: parsed strictly; bad values become empty, never guessed", () => {
  assertEquals(parseDraft({ kind: "request", title: " 将生の保育園に下着を2枚持っていく ", date: "2026-10-01", time: "7:05", daypart: "morning", who: "partner", message: "よろしく" }), {
    kind: "request", title: "将生の保育園に下着を2枚持っていく", date: "2026-10-01", time: "07:05", daypart: "morning", who: "partner", message: "よろしく",
  });
  assertEquals(parseDraft({ kind: "task", title: "x", date: "2026-02-30", time: "25:00", daypart: "dawn", who: "grandma" }), {
    kind: "task", title: "x", date: null, time: null, daypart: null, who: null, message: null,
  });
  for (const bad of [null, "x", [], { kind: "share", title: "x" }, { kind: "task" }, { kind: "task", title: "あ".repeat(81) }]) {
    assertEquals(parseDraft(bad), undefined, JSON.stringify(bad));
  }
  const plan = parsePlan('{"reply":"了解！","actions":[{"type":"create","text":"t","draft":{"kind":"task","title":"ゴミ出し","date":"2026-10-01"}}],"confidence":"high"}');
  assertEquals(plan?.actions[0], { type: "create", text: "t", draft: { kind: "task", title: "ゴミ出し", date: "2026-10-01", time: null, daypart: null, who: null, message: null } });
  // An unusable draft does not reject the plan: the sentence takes the old path.
  assertEquals(parsePlan('{"reply":"了解！","actions":[{"type":"create","text":"t","draft":{"kind":"?"}}],"confidence":"high"}')?.actions[0], { type: "create", text: "t" });
});

const ctx = { actorId: "papa-id", partnerId: "mama-id", partnerLabel: "ママ", today: "2026-09-30" };

Deno.test("draft -> card: the live case is a request to the dropoff person, with the child, the count and 朝", () => {
  const built = draftToPending({
    kind: "request", title: "将生の保育園に下着を2枚持っていく", date: "2026-10-01", time: null, daypart: "morning", who: "partner",
    message: "明日の朝、将生の保育園に下着を2枚持っていってもらえる？",
  }, ctx);
  assertEquals(built, {
    actionType: "request_create",
    payload: {
      title: "将生の保育園に下着を2枚持っていく", scheduled_date: "2026-10-01", due_local_time: "08:00", daypart: "morning",
      recipient_user_id: "mama-id", target_label: "ママ", shared_message: "明日の朝、将生の保育園に下着を2枚持っていってもらえる？",
    },
  });
});

Deno.test("draft -> card: own task, event, shopping; no partner -> old path", () => {
  const own = draftToPending({ kind: "task", title: "ゴミ出し", date: null, time: "07:00", daypart: null, who: null, message: null }, ctx);
  assertEquals(own?.actionType, "task_create_once");
  assertEquals([own?.payload.planned_assignee_user_id, own?.payload.scheduled_date, own?.payload.due_local_time, own?.payload.calendar_visibility, own?.payload.target_label],
    ["papa-id", "2026-09-30", "07:00", "hidden", "自分"]);
  const event = draftToPending({ kind: "event", title: "皮膚科", date: "2026-10-03", time: "10:00", daypart: null, who: "partner", message: null }, ctx);
  assertEquals([event?.actionType, event?.payload.explicit_kind, event?.payload.calendar_visibility, event?.payload.planned_assignee_user_id],
    ["task_create_once", "event", "special", "mama-id"]);
  const shop = draftToPending({ kind: "shopping", title: "牛乳", date: null, time: null, daypart: null, who: "me", message: null }, ctx);
  assertEquals([shop?.actionType, shop?.payload.assignee_user_id, shop?.payload.purchase_method], ["shopping_item_add", "papa-id", "store"]);
  assertEquals(draftToPending({ kind: "request", title: "x", date: null, time: null, daypart: null, who: "partner", message: null }, { ...ctx, partnerId: null }), null);
});

Deno.test("draft -> card: an edit replaces what the model filled in and keeps the rest", () => {
  const base = {
    title: "保育園に下着を持っていく", scheduled_date: "2026-10-01", due_local_time: null, recipient_user_id: "mama-id",
    shared_message: "保育園に下着を持っていくをお願いできますか？", raw_text: "明日、…", line_edit_mode: true,
  };
  const edited = draftToPending({ kind: "task", title: "将生の保育園に下着を2枚持っていく", date: null, time: null, daypart: "morning", who: "me", message: null }, ctx, base);
  assertEquals(edited?.actionType, "task_create_once");
  const p = edited!.payload;
  assertEquals([p.title, p.scheduled_date, p.due_local_time, p.planned_assignee_user_id, p.raw_text], ["将生の保育園に下着を2枚持っていく", "2026-10-01", "08:00", "papa-id", "明日、…"]);
  // The old addressee, message and edit flag do not linger.
  assertEquals([p.recipient_user_id, p.shared_message, p.line_edit_mode], [undefined, undefined, undefined]);
});

Deno.test("prompt: tomorrow's dropoff person and the draft's fields reach the model", () => {
  const p = buildUnderstandPrompt(snap({
    transport: [
      { date: "2026-09-30", dropoff: { who: "me", time: "07:30" }, pickup: { who: "partner", time: "18:20" } },
      { date: "2026-10-01", dropoff: { who: "partner", time: "07:30" }, pickup: null },
    ],
    pendingDraft: { kind: "request", title: "保育園に下着を持っていく", date: "2026-10-01", time: null, daypart: null, who: "partner" },
  }), "将生のね。あと朝だから朝担当の人でよろしくね");
  for (const needle of [
    '"日付":"2026-10-01","送り":"ママ 07:30","お迎え":"なし"', '"送り":"パパ 07:30","お迎え":"ママ 18:20"',
    '"題名":"保育園に下着を持っていく","日付":"2026-10-01"', '"担当":"ママ"', '"date":"2026-10-01"',
  ]) assertEquals(p.includes(needle), true, needle);
});

Deno.test("snapshot: the waiting draft is described with its fields", () => {
  assertEquals(describePendingDraft({ action_type: "request_create", normalized_payload: { title: "下着", scheduled_date: "2026-10-01", recipient_user_id: "mama-id", daypart: "morning", due_local_time: "08:00" } }, "papa-id"),
    { kind: "request", title: "下着", date: "2026-10-01", time: "08:00", daypart: "morning", who: "partner" });
  assertEquals(describePendingDraft({ action_type: "task_create_once", normalized_payload: { title: "皮膚科", calendar_visibility: "special", planned_assignee_user_id: "papa-id" } }, "papa-id")?.kind, "event");
  assertEquals(describePendingDraft(null, "papa-id"), null);
});

Deno.test("run: the draft rides along with the hand-off", async () => {
  const draft = { kind: "task" as const, title: "ゴミ出し", date: null, time: null, daypart: null, who: null, message: null };
  const out = await runPlan({ understanding: "", reply: "了解！", confidence: "high", actions: [{ type: "edit_draft", text: "ゴミ出し", draft }] },
    snap({ pendingDraft: { kind: "task", title: "ごみ" } }), fakeEffects().effects, "ゴミ出しね");
  assertEquals(out, { done: false, continueWith: { text: "ゴミ出し", mode: "edit", draft }, pendingReply: "" });
});

// Live 2026-10-02 11:20-11:22: "朝の仕事は全部やりました！" -- the model listed 9 morning
// tasks, 4 were completed (the old cap of 4 actions), and it took three messages. Then
// the Codmon submit stayed open without a word.
const morning = (over: Partial<Snapshot> = {}) => snap({
  tasks: [
    { ref: "t1", id: "id-1", title: "送り", who: "me", due: "07:30", status: "todo", code: "dropoff", phase: "morning" },
    { ref: "t2", id: "id-2", title: "朝ごはん", who: "me", due: null, status: "todo", code: null, phase: "morning" },
    { ref: "t3", id: "id-3", title: "子供の着替え準備", who: "me", due: null, status: "todo", code: null, phase: "morning" },
    { ref: "t4", id: "id-4", title: "詩乃の薬", who: "anyone", due: null, status: "todo", code: null, phase: "morning" },
    { ref: "t5", id: "id-5", title: "詩乃：コドモン入力（朝食）", who: "me", due: null, status: "todo", code: "codmon_shino_breakfast_input", phase: "morning" },
    { ref: "t6", id: "id-6", title: "詩乃：コドモン入力（昨日の夕飯・様子）", who: "partner", due: null, status: "todo", code: "codmon_shino_previous_input", phase: "morning" },
    { ref: "t7", id: "id-7", title: "コドモン送信", who: null, due: "09:15", status: "todo", code: "codmon_submit", phase: "morning" },
    { ref: "t8", id: "id-8", title: "洗濯", who: "me", due: null, status: "done", code: null, phase: "evening" },
  ],
  ...over,
});

Deno.test("bulk: complete_tasks completes every listed task in one message, past the 4-action cap", async () => {
  const plan = parsePlan('{"reply":"おつかれさま！","actions":[{"type":"complete_tasks","refs":["t1","t2","t3","t4","t5","t8","t1"],"by":"self"}],"confidence":"high"}')!;
  const guarded = guardPlan(plan, morning())!;
  // Duplicates and the already-done task are dropped.
  assertEquals(guarded.actions.map((a) => (a as { ref: string }).ref), ["t1", "t2", "t3", "t4", "t5"]);
  const { log, effects } = fakeEffects();
  await runPlan(guarded, morning(), effects, "朝の仕事は全部やりました！");
  assertEquals(log.filter((l) => l.startsWith("done:")).length, 5);
  // One reply; the completion lines are stacked; the Codmon submit is asked about, one tap closes it.
  const sent = log.at(-1)!;
  assertEquals(sent.startsWith("SEND:おつかれさま！\n\n✓ 送り\n✓ 朝ごはん\n✓ 子供の着替え準備\n✓ 詩乃の薬\n✓ 詩乃：コドモン入力（朝食）\n\nコドモンは送信まで済んだ？（ママの「詩乃：コドモン入力（昨日の夕飯・様子）」がまだ未完了です）"), true, sent);
  assertEquals(sent.includes('"data":"action=complete_task&task_id=id-7"'), true);
});

Deno.test("bulk: the Codmon submit is held while the partner's input is open; an explicit report closes it", async () => {
  const bulk = guardPlan(parsePlan('{"reply":"おつかれさま！コドモンは送信まで済んだ？","actions":[{"type":"complete_tasks","refs":["t1","t7"],"by":"self"}],"confidence":"high"}')!, morning())!;
  const a = fakeEffects();
  await runPlan(bulk, morning(), a.effects, "朝の全部やった");
  assertEquals(a.log.includes("done:id-7:self"), false);
  // The model already asked in its own words: no second question, only the button.
  assertEquals(a.log.at(-1)!.split("コドモンは送信まで済んだ？").length, 2);
  assertEquals(a.log.at(-1)!.includes("action=complete_task&task_id=id-7"), true);

  const explicit = guardPlan(parsePlan('{"reply":"了解！","actions":[{"type":"complete_task","ref":"t7","by":"self"}],"confidence":"high"}')!, morning())!;
  const b = fakeEffects();
  await runPlan(explicit, morning(), b.effects, "コドモンも終わっているよ！");
  assertEquals(b.log[0], "done:id-7:self");
  assertEquals(b.log.at(-1)!.includes("送信まで済んだ"), false);

  // Bulk with nothing of the partner's open: the submit is closed with the rest.
  const allMine = morning({ tasks: morning().tasks.filter((t) => t.ref !== "t6") });
  const c = fakeEffects();
  await runPlan(guardPlan(parsePlan('{"reply":"おつかれさま！","actions":[{"type":"complete_tasks","refs":["t1","t7"],"by":"self"}],"confidence":"high"}')!, allMine)!, allMine, c.effects, "朝の全部やった");
  assertEquals(c.log.includes("done:id-7:self"), true);
  assertEquals(c.log.at(-1)!.includes("送信まで済んだ"), false);
});

Deno.test("bulk: 「朝の全部」 is picked by the code -- unassigned included, the partner's left, Codmon asked", async () => {
  const s = morning({ tasks: [...morning().tasks, { ref: "t9", id: "id-9", title: "お風呂", who: "me", due: "20:00", status: "todo", code: null, phase: "evening" }] });
  const plan = parsePlan('{"reply":"おつかれさま！","actions":[{"type":"complete_tasks","refs":[],"all":"morning","by":"self"}],"confidence":"high"}')!;
  const guarded = guardPlan(plan, s)!;
  // t6 is ママ's input, t8 is done, t9 is evening; t7 (Codmon submit) goes to the hold check.
  assertEquals(guarded.actions.map((a) => (a as { ref: string }).ref), ["t1", "t2", "t3", "t4", "t5", "t7"]);
  const { log, effects } = fakeEffects();
  await runPlan(guarded, s, effects, "朝の仕事は全部やりました！");
  assertEquals(log.includes("done:id-7:self"), false);
  assertEquals(log.at(-1)!.includes("コドモンは送信まで済んだ？"), true);
  // Everything already done: the reply alone, nothing recorded, no fallback.
  const allDone = morning({ tasks: morning().tasks.map((t) => ({ ...t, status: "done" as const })) });
  assertEquals(guardPlan(plan, allDone)?.actions, []);
  // ママがやってくれた: by=partner takes the partner's too.
  const byPartner = guardPlan(parsePlan('{"reply":"ありがとう！","actions":[{"type":"complete_tasks","refs":[],"all":"morning","by":"partner"}],"confidence":"high"}')!, s)!;
  assertEquals(byPartner.actions.some((a) => (a as { ref: string }).ref === "t6"), true);
});

Deno.test("model: the household setting wins when it is a valid Gemini id, else the environment", () => {
  Deno.env.set("GEMINI_MODEL_LINE_UNDERSTAND", "gemini-3.1-flash-lite");
  try {
    assertEquals(resolveUnderstandModel("gemini-3.5-flash"), "gemini-3.5-flash");
    assertEquals(resolveUnderstandModel(null), "gemini-3.1-flash-lite");
    assertEquals(resolveUnderstandModel("gemini-3.5-flash:generateContent?key=x"), "gemini-3.1-flash-lite");
    assertEquals(resolveUnderstandModel("../models/other"), "gemini-3.1-flash-lite");
  } finally {
    Deno.env.delete("GEMINI_MODEL_LINE_UNDERSTAND");
  }
});
