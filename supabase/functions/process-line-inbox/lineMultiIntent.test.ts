import { assertEquals } from "jsr:@std/assert@1";
import {
  activeMultiIntentCandidates,
  assignCandidateOperationIds,
  decomposeLineConversationCandidates,
  deterministicLineConversationCandidates,
  isMultiIntentMessage,
  normalizeSemanticDecomposition,
} from "./lineMultiIntent.ts";

const NOW = new Date("2026-09-09T03:00:00Z");

function model(candidates: Array<Record<string, unknown>>): string {
  return JSON.stringify({
    candidates: candidates.map((candidate) => ({
      scheduled_date: "2026-09-10",
      due_local_time: null,
      daypart: null,
      target_role: null,
      shared_message: null,
      subtasks: [],
      context: null,
      calendar_visibility: "hidden",
      missing_fields: [],
      ambiguous_fields: [],
      confidence: 0.95,
      ...candidate,
    })),
  });
}

function task(title: string, sourceText: string, extra: Record<string, unknown> = {}) {
  return { kind: "task", title, source_text: sourceText, ...extra };
}
function shopping(title: string, sourceText: string, extra: Record<string, unknown> = {}) {
  return { kind: "shopping", title, source_text: sourceText, ...extra };
}
function request(title: string, sourceText: string, role: string | null, extra: Record<string, unknown> = {}) {
  return {
    kind: "request", title, source_text: sourceText, target_role: role,
    shared_message: `${title}をお願いできますか？`, ...extra,
  };
}

async function decompose(raw: string, canned: string) {
  return await decomposeLineConversationCandidates(raw, NOW, () => Promise.resolve(canned));
}

Deno.test("mandatory corpus: punctuation-free Japanese becomes three semantic candidates", async () => {
  const raw = "明日ゴミ出しして牛乳も買ってママにお迎えお願い";
  const candidates = await decompose(raw, model([
    task("ゴミ出し", "明日ゴミ出しして"),
    shopping("牛乳", "牛乳も買って"),
    request("お迎え", "ママにお迎えお願い", "mama"),
  ]));
  assertEquals(candidates.length, 3);
  assertEquals(candidates.map((c) => c.kind), ["task", "shopping", "request"]);
  assertEquals(candidates[2].intent?.targetRole, "mama");
});

Deno.test("mandatory corpus: comma-only and して、して are semantic, not punctuation gates", async () => {
  for (const raw of [
    "ゴミ出しして、牛乳買って、洗濯して",
    "ゴミ出しして、牛乳も買って",
  ]) {
    const candidates = await decompose(raw, model([
      task("ゴミ出し", "ゴミ出しして"),
      shopping("牛乳", raw.includes("牛乳買って") ? "牛乳買って" : "牛乳も買って"),
      ...(raw.includes("洗濯") ? [task("洗濯", "洗濯して")] : []),
    ]));
    assertEquals(candidates.length, raw.includes("洗濯") ? 3 : 2);
  }
});

Deno.test("mandatory corpus: spoken colloquial Japanese preserves two intents", async () => {
  const raw = "えっとさ明日ゴミ出しやっといてあと牛乳買っといて";
  const candidates = await decompose(raw, model([
    task("ゴミ出し", "明日ゴミ出しやっといて"),
    shopping("牛乳", "牛乳買っといて"),
  ]));
  assertEquals(candidates.map((c) => c.kind), ["task", "shopping"]);
});

Deno.test("mandatory corpus: five intents and same-kind intents are never merged", async () => {
  const raw = "ゴミ出しして洗濯して牛乳買ってパン買ってママにお迎えお願い";
  const candidates = await decompose(raw, model([
    task("ゴミ出し", "ゴミ出しして"),
    task("洗濯", "洗濯して"),
    shopping("牛乳", "牛乳買って"),
    shopping("パン", "パン買って"),
    request("お迎え", "ママにお迎えお願い", "mama"),
  ]));
  assertEquals(candidates.length, 5);
  assertEquals(candidates.map((c) => c.kind), ["task", "task", "shopping", "shopping", "request"]);
});

Deno.test("mandatory corpus: exactly one ambiguous field targets only that candidate", async () => {
  const raw = "明日ゴミ出ししてお迎えお願い";
  const candidates = await decompose(raw, model([
    task("ゴミ出し", "明日ゴミ出しして"),
    request("お迎え", "お迎えお願い", null, {
      missing_fields: ["assignee"], ambiguous_fields: ["assignee"], confidence: 0.55,
    }),
  ]));
  assertEquals(candidates[0].missingFields, []);
  assertEquals(candidates[1].missingFields, ["assignee"]);
  assertEquals(candidates[1].ambiguousFields, ["assignee"]);
});

Deno.test("mandatory corpus: correction 'それ日曜だった' keeps candidate identity and corrected date", async () => {
  const raw = "土曜のお迎えママお願い。それ日曜だった";
  const candidates = await decompose(raw, model([
    request("お迎え", "土曜のお迎えママお願い", "mama", { scheduled_date: "2026-09-13" }),
  ]));
  assertEquals(candidates.length, 1);
  assertEquals(candidates[0].intent?.scheduledDate, "2026-09-13");
  assertEquals(candidates[0].intent?.targetRole, "mama");
});

Deno.test("strict model boundary rejects invented non-source spans and falls back deterministically", async () => {
  const raw = "明日オムツをAmazonで買って";
  const invalid = model([shopping("オムツ", "入力に存在しない文")]);
  const direct = normalizeSemanticDecomposition(invalid, raw);
  assertEquals(direct, []);
  const candidates = await decompose(raw, invalid);
  assertEquals(candidates.length, 1);
  assertEquals(candidates[0].kind, "shopping");
});

Deno.test("candidate operation identity is assigned before review and remains stable", async () => {
  const raw = "ゴミ出しして牛乳買って";
  const candidates = await decompose(raw, model([
    task("ゴミ出し", "ゴミ出しして"), shopping("牛乳", "牛乳買って"),
  ]));
  const assigned = assignCandidateOperationIds(candidates, (id) => `op-${id}`);
  assertEquals(assigned.map((c) => c.operationId), ["op-c1", "op-c2"]);
  assertEquals(assignCandidateOperationIds(assigned, () => "new").map((c) => c.operationId), ["op-c1", "op-c2"]);
});

Deno.test("pending reference/correction fallback retains previous candidate semantics", () => {
  const candidates = deterministicLineConversationCandidates(
    "金曜のお迎えママお願い……あ、やっぱ土曜。牛乳も買って。",
    new Date("2026-09-07T05:00:00Z"),
  );
  assertEquals(candidates.length, 2);
  assertEquals(candidates[0].kind, "request");
  assertEquals(candidates[0].intent?.targetRole, "mama");
  assertEquals(candidates[0].intent?.scheduledDate, "2026-09-12");
  assertEquals(candidates[0].sourceText.includes("訂正"), true);
  assertEquals(candidates[1].kind, "shopping");
});

Deno.test("one candidate can be cancelled while the others remain executable", () => {
  const active = activeMultiIntentCandidates([
    {
      candidate_id: "c1", operation_id: "00000000-0000-4000-8000-000000000001",
      kind: "task", title: "水着を準備", source_text: "水着準備", source_span: null,
      confidence: 0.9, ambiguous_fields: [], duplicate_match: null,
      status: "draft", missing_fields: [], action_type: "task_create_once", payload: { title: "水着を準備" },
    },
    {
      candidate_id: "c2", operation_id: "00000000-0000-4000-8000-000000000002",
      kind: "shopping", title: "牛乳", source_text: "牛乳", source_span: null,
      confidence: 0.9, ambiguous_fields: [], duplicate_match: null,
      status: "cancelled", missing_fields: [], action_type: "shopping_item_add", payload: { title: "牛乳" },
    },
    {
      candidate_id: "c3", operation_id: "00000000-0000-4000-8000-000000000003",
      kind: "task", title: "洗濯", source_text: "洗濯", source_span: null,
      confidence: 0.9, ambiguous_fields: [], duplicate_match: null,
      status: "draft", missing_fields: [], action_type: "task_create_once", payload: { title: "洗濯" },
    },
  ]);
  assertEquals(active.map((candidate) => candidate.candidate_id), ["c1", "c3"]);
});

Deno.test("one candidate remains a normal preview, not a forced group", () => {
  const candidates = deterministicLineConversationCandidates(
    "明日オムツをAmazonで買って",
    new Date("2026-08-22T09:00:00Z"),
  );
  assertEquals(candidates.length, 1);
  assertEquals(candidates[0].kind, "shopping");
  assertEquals(isMultiIntentMessage(candidates), false);
});


Deno.test("model cannot invent a family role when source text has none", () => {
  const raw = "明日のお迎えお願い";
  const direct = normalizeSemanticDecomposition(model([
    request("お迎え", raw, "mama"),
  ]), raw);
  assertEquals(direct[0].intent?.targetRole, null);
});

Deno.test("explicit family role in source text overrides missing model role", () => {
  const raw = "ママに明日のお迎えお願い";
  const direct = normalizeSemanticDecomposition(model([
    request("お迎え", raw, null),
  ]), raw);
  assertEquals(direct[0].intent?.targetRole, "mama");
});

Deno.test("colloquial role correction selects the final role", () => {
  const raw = "明日お迎えママお願い。いやパパだった";
  const direct = normalizeSemanticDecomposition(model([
    request("お迎え", raw, null),
  ]), raw);
  assertEquals(direct[0].intent?.targetRole, "papa");
});

Deno.test("daypart must not silently become a concrete due time", () => {
  const raw = "明日朝ゴミ出しお願い";
  const direct = normalizeSemanticDecomposition(model([
    request("ゴミ出し", raw, null, { daypart: "morning", due_local_time: "09:00" }),
  ]), raw);
  assertEquals(direct[0].intent?.daypart, "morning");
  assertEquals(direct[0].intent?.dueLocalTime, null);
});

Deno.test("explicit clock time may survive model normalization", () => {
  const raw = "明日7時30分までに水筒準備";
  const direct = normalizeSemanticDecomposition(model([
    task("水筒準備", raw, { due_local_time: "07:30" }),
  ]), raw);
  assertEquals(direct[0].intent?.dueLocalTime, "07:30");
});


Deno.test("fallback splits shopping plus pickup request across a comma", () => {
  const raw = "牛乳買って、明日のお迎えママお願い";
  const candidates = deterministicLineConversationCandidates(raw, new Date("2026-09-11T03:00:00Z"));
  assertEquals(candidates.map((candidate) => candidate.kind), ["shopping", "request"]);
  assertEquals(candidates[0].intent?.scheduledDate, "2026-09-11");
  assertEquals(candidates[1].intent?.scheduledDate, "2026-09-12");
  assertEquals(candidates[1].intent?.targetRole, "mama");
});

Deno.test("fallback splits share preparation and low-stock shopping", () => {
  const raw = "保育園から明日水遊びって、タオル準備して、牛乳もなくなる";
  const candidates = deterministicLineConversationCandidates(raw, new Date("2026-09-11T03:00:00Z"));
  assertEquals(candidates.map((candidate) => candidate.kind), ["share", "task", "shopping"]);
  assertEquals(candidates[1].intent?.scheduledDate, "2026-09-12");
  assertEquals(candidates[2].intent?.scheduledDate, "2026-09-12");
});

Deno.test("fallback preserves terse task boundaries across commas", () => {
  const raw = "明日遠足だから水筒帽子着替え準備して、朝ゴミ出し、帰り牛乳買う";
  const candidates = deterministicLineConversationCandidates(raw, new Date("2026-09-11T03:00:00Z"));
  assertEquals(candidates.map((candidate) => candidate.kind), ["task", "task", "shopping"]);
  assertEquals(candidates[1].intent?.daypart, "morning");
  assertEquals(candidates[2].intent?.scheduledDate, "2026-09-12");
});

Deno.test("fallback applies comma role correction before later shopping", () => {
  const raw = "明日迎えはママ、いや違うパパ、牛乳も買って";
  const candidates = deterministicLineConversationCandidates(raw, new Date("2026-09-11T03:00:00Z"));
  assertEquals(candidates.map((candidate) => candidate.kind), ["task", "shopping"]);
  assertEquals(candidates[0].intent?.targetRole, "papa");
  assertEquals(candidates[0].intent?.scheduledDate, "2026-09-12");
});

Deno.test("model completed purchase is normalized to actual", () => {
  const raw = "牛乳買った";
  const direct = normalizeSemanticDecomposition(model([
    shopping("牛乳の購入", raw),
  ]), raw);
  assertEquals(direct[0].kind, "actual");
  assertEquals(direct[0].intent, null);
});

Deno.test("model store visit without a purchase is normalized to task", () => {
  const raw = "帰り薬局寄る";
  const direct = normalizeSemanticDecomposition(model([
    shopping("薬局で薬の購入", raw),
  ]), raw);
  assertEquals(direct[0].kind, "task");
  assertEquals(direct[0].intent?.kind, "task");
});
