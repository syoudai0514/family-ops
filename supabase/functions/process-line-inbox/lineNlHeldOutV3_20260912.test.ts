import { assertEquals } from "jsr:@std/assert@1";
import {
  lineNonMutationDisposition,
  linePendingFollowUpKind,
} from "./lineConversation.ts";
import { normalizeSemanticDecomposition } from "./lineMultiIntent.ts";

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
      confidence: 0.89,
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

// Fresh held-out v3. Do not tune implementation against these cases while
// still calling this set held-out. Any failure makes this file diagnostic.

Deno.test("NL-ADDR-H3-001: asking how to phrase a family request is assistant advice", () => {
  assertEquals(
    lineNonMutationDisposition("これを家族に頼むのって、どう言うのがいい？"),
    "assistant_conversation",
  );
});

Deno.test("NL-ADDR-H3-002: explicit no-notification consultation is non-mutating", () => {
  assertEquals(
    lineNonMutationDisposition("今は通知しないで、相談だけにして"),
    "assistant_conversation",
  );
});

Deno.test("NL-ADDR-H3-003: draft-only wording request is non-mutating", () => {
  assertEquals(
    lineNonMutationDisposition("送る前の下書きだけ作って"),
    "assistant_conversation",
  );
});

Deno.test("NL-ADDR-H3-004: explicit family request remains actionable", () => {
  const raw = "ママに洗濯たたむのお願いして";
  assertEquals(lineNonMutationDisposition(raw), null);
  assertEquals(
    summary(raw, [{ kind: "request", title: "洗濯たたむ", sourceText: raw, targetRole: "mama" }]),
    [{ kind: "request", sourceText: raw, targetRole: "mama" }],
  );
});

Deno.test("NL-ADDR-H3-005: generic 'can you ask/do this' stays ambiguous without recipient", () => {
  assertEquals(lineNonMutationDisposition("これ頼める？"), "ambiguous");
});

Deno.test("NL-ADDR-H3-006: conditional family desire plus no-send stays conversation", () => {
  assertEquals(
    lineNonMutationDisposition("もし大丈夫ならパパにお願いしたい、まだ送らないで"),
    "assistant_conversation",
  );
});

Deno.test("NL-CTX-H3-001: correction from family-send assumption to AI consultation repairs pending action", () => {
  assertEquals(
    linePendingFollowUpKind("いや、家族に送るんじゃなくてAIに相談"),
    "assistant_repair",
  );
});

Deno.test("NL-CTX-H3-002: reverse correction from AI to family action remains actionable", () => {
  assertEquals(
    lineNonMutationDisposition("AIへの相談じゃなくてママに頼みたい"),
    null,
  );
});

Deno.test("NL-BROKEN-H3-001: broken speech with no-notification consultation stays safe", () => {
  assertEquals(
    lineNonMutationDisposition("つうちなし そうだんだけ"),
    "assistant_conversation",
  );
});

Deno.test("NL-BROKEN-H3-002: broken explicit family action remains actionable", () => {
  assertEquals(lineNonMutationDisposition("まま ごみだし たのむ"), null);
});

Deno.test("NL-MIX-H3-001: wording review span is discarded while explicit shopping survives", () => {
  const raw = "まず言い方見て、あとパパに牛乳買ってもらって";
  assertEquals(
    summary(raw, [
      { kind: "share", title: "言い方", sourceText: "まず言い方見て" },
      { kind: "shopping", title: "牛乳", sourceText: "あとパパに牛乳買ってもらって", targetRole: "papa" },
    ]),
    [{ kind: "shopping", sourceText: "あとパパに牛乳買ってもらって", targetRole: "papa" }],
  );
});

Deno.test("NL-MIX-H3-002: advice span is discarded while separate explicit family action survives", () => {
  const raw = "迎えどう頼むか相談、牛乳はママに買って";
  assertEquals(
    summary(raw, [
      { kind: "request", title: "迎え", sourceText: "迎えどう頼むか相談", targetRole: null },
      { kind: "shopping", title: "牛乳", sourceText: "牛乳はママに買って", targetRole: "mama" },
    ]),
    [{ kind: "shopping", sourceText: "牛乳はママに買って", targetRole: "mama" }],
  );
});
