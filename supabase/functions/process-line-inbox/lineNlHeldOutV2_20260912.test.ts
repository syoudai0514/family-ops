import { assertEquals } from "jsr:@std/assert@1";
import {
  lineNonMutationDisposition,
  linePendingFollowUpKind,
} from "./lineConversation.ts";
import {
  decomposeLineConversationCandidates,
  normalizeSemanticDecomposition,
} from "./lineMultiIntent.ts";

type Row = {
  kind: "task" | "request" | "shopping" | "share" | "actual";
  title: string;
  sourceText: string;
  targetRole?: "papa" | "mama" | null;
};

function model(rows: Row[]): string {
  return JSON.stringify({
    candidates: rows.map((row) => ({
      kind: row.kind,
      title: row.title,
      source_text: row.sourceText,
      scheduled_date: "2026-09-13",
      due_local_time: null,
      daypart: null,
      target_role: row.targetRole ?? null,
      shared_message: row.kind === "request" ? `${row.title}をお願いできますか？` : null,
      subtasks: [],
      context: null,
      calendar_visibility: "hidden",
      missing_fields: [],
      ambiguous_fields: [],
      confidence: 0.9,
    })),
  });
}

function summary(raw: string, rows: Row[]) {
  return normalizeSemanticDecomposition(model(rows), raw).map((candidate) => ({
    kind: candidate.kind,
    sourceText: candidate.sourceText,
    targetRole: candidate.intent?.targetRole ?? null,
  }));
}

// Fresh held-out v2. These phrasings are intentionally distinct from the
// development set and the first held-out set that became diagnostic evidence.

Deno.test("NL-ADDR-H2-001: advice about how to ask spouse remains conversation", () => {
  assertEquals(
    lineNonMutationDisposition("夫にお願いするならどう頼むのが自然かな"),
    "assistant_conversation",
  );
});

Deno.test("NL-ADDR-H2-002: feasibility question is not authorization", () => {
  assertEquals(
    lineNonMutationDisposition("明日の迎えってお願いできそう？"),
    "assistant_conversation",
  );
});

Deno.test("NL-ADDR-H2-003: explicit wording-only constraint blocks mutation", () => {
  assertEquals(
    lineNonMutationDisposition("送信はしないで、言い方だけ一緒に考えて"),
    "assistant_conversation",
  );
});

Deno.test("NL-ADDR-H2-004: clear family action still reaches action path", () => {
  const raw = "パパに明日のゴミ出しお願いして";
  assertEquals(lineNonMutationDisposition(raw), null);
  assertEquals(
    summary(raw, [{ kind: "request", title: "ゴミ出し", sourceText: raw, targetRole: "papa" }]),
    [{ kind: "request", sourceText: raw, targetRole: "papa" }],
  );
});

Deno.test("NL-ADDR-H2-005: generic object plus question stays ambiguous", () => {
  assertEquals(lineNonMutationDisposition("それお願いできる？"), "ambiguous");
});

Deno.test("NL-ADDR-H2-006: conditional partner action remains conversation", () => {
  assertEquals(
    lineNonMutationDisposition("大丈夫そうなら妻に頼みたいんだけど、どうかな"),
    "assistant_conversation",
  );
});

Deno.test("NL-CTX-H2-001: correction prefix plus assistant target repairs pending action", () => {
  assertEquals(linePendingFollowUpKind("違うよ、AIに相談してる"), "assistant_repair");
});

Deno.test("NL-CTX-H2-002: natural cancel after edits is recognized", () => {
  assertEquals(linePendingFollowUpKind("やっぱりさっきのなし"), "cancel");
});

Deno.test("NL-BROKEN-H2-001: speech-like advice survives filler and kana", () => {
  assertEquals(
    lineNonMutationDisposition("えーっと ままに どうたのむのがいいかな"),
    "assistant_conversation",
  );
});

Deno.test("NL-BROKEN-H2-002: explicit family request in kana is not swallowed", () => {
  const raw = "ぱぱに あした ごみだし おねがいして";
  assertEquals(lineNonMutationDisposition(raw), null);
});

Deno.test("NL-MIX-H2-001: review span is filtered while explicit request survives", () => {
  const raw = "この言い方見て、それとは別にママに洗濯お願いして";
  assertEquals(
    summary(raw, [
      { kind: "share", title: "言い方", sourceText: "この言い方見て" },
      { kind: "request", title: "洗濯", sourceText: "それとは別にママに洗濯お願いして", targetRole: "mama" },
    ]),
    [{ kind: "request", sourceText: "それとは別にママに洗濯お願いして", targetRole: "mama" }],
  );
});

Deno.test("NL-MIX-H2-002: no-send span is filtered while explicit shopping survives", () => {
  const raw = "この文はまだ送らない、牛乳はパパに買ってもらって";
  assertEquals(
    summary(raw, [
      { kind: "request", title: "文を送る", sourceText: "この文はまだ送らない" },
      { kind: "shopping", title: "牛乳", sourceText: "牛乳はパパに買ってもらって", targetRole: "papa" },
    ]),
    [{ kind: "shopping", sourceText: "牛乳はパパに買ってもらって", targetRole: "papa" }],
  );
});

// Structural regression: a valid AI no-action result must be authoritative.
// Provider unavailability or malformed output may use deterministic fallback,
// but valid {candidates: []} must not be reinterpreted into a mutation.
Deno.test("NL-STRUCT-001: valid AI no-action result does not fall back to deterministic mutation", async () => {
  const candidates = await decomposeLineConversationCandidates(
    "迎えお願い",
    new Date("2026-09-12T00:00:00Z"),
    () => Promise.resolve(JSON.stringify({ candidates: [] })),
  );
  assertEquals(candidates, []);
});

Deno.test("NL-STRUCT-002: unavailable semantic provider still permits deterministic availability fallback", async () => {
  const candidates = await decomposeLineConversationCandidates(
    "明日の迎えお願い",
    new Date("2026-09-12T00:00:00Z"),
    () => Promise.resolve(null),
  );
  assertEquals(candidates.length > 0, true);
});

Deno.test("NL-STRUCT-003: malformed semantic output still permits deterministic availability fallback", async () => {
  const candidates = await decomposeLineConversationCandidates(
    "明日の迎えお願い",
    new Date("2026-09-12T00:00:00Z"),
    () => Promise.resolve("not-json"),
  );
  assertEquals(candidates.length > 0, true);
});
