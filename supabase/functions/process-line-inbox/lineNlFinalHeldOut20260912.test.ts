import { assertEquals } from "jsr:@std/assert@1";
import { lineNonMutationDisposition, linePendingFollowUpKind } from "./lineConversation.ts";
import { decomposeLineConversationCandidates } from "./lineMultiIntent.ts";

// FINAL FRESH HELD-OUT CORPUS.
// Sealed only after CI #1140 was fully green. No implementation may be tuned
// from these rows while still calling this set held-out.

Deno.test("NL-HFINAL-001: indirect tone advice stays with assistant", () => {
  assertEquals(lineNonMutationDisposition("パートナーに頼む文面、角が立たない感じならどう思う？"), "assistant_conversation");
});

Deno.test("NL-HFINAL-002: pre-send message review stays with assistant", () => {
  assertEquals(lineNonMutationDisposition("家族に送る前にメッセージ見てもらえる？"), "assistant_conversation");
});

Deno.test("NL-HFINAL-003: explicit no-send wording consultation is non-mutating", () => {
  assertEquals(lineNonMutationDisposition("送信しないで、この言い方だけ一緒に考えて"), "assistant_conversation");
});

Deno.test("NL-HFINAL-004: generic referent plus request remains ambiguous", () => {
  assertEquals(lineNonMutationDisposition("それって頼める？"), "ambiguous");
});

Deno.test("NL-HFINAL-005: explicit spouse action remains actionable", () => {
  assertEquals(lineNonMutationDisposition("妻に明日の迎えお願いして"), null);
});

Deno.test("NL-HFINAL-006: explicit papa shopping action remains actionable", () => {
  assertEquals(lineNonMutationDisposition("パパに牛乳買ってもらって"), null);
});

Deno.test("NL-HFINAL-007: mixed semantic output filters advice but preserves family action", async () => {
  const text = "どういう言い方がいい？別件でママにゴミ出しお願い";
  const raw = JSON.stringify({ candidates: [
    { kind: "request", title: "言い方", source_text: "どういう言い方がいい？", scheduled_date: "2026-09-12", target_role: null, missing_fields: [], ambiguous_fields: [], confidence: 0.92 },
    { kind: "request", title: "ゴミ出し", source_text: "ママにゴミ出しお願い", scheduled_date: "2026-09-12", target_role: "mama", shared_message: "ゴミ出しをお願いできますか？", missing_fields: [], ambiguous_fields: [], confidence: 0.95 },
  ] });
  const candidates = await decomposeLineConversationCandidates(text, new Date("2026-09-12T00:00:00Z"), () => Promise.resolve(raw));
  assertEquals(candidates.length, 1);
  assertEquals(candidates[0].title, "ゴミ出し");
  assertEquals(candidates[0].intent?.targetRole, "mama");
});

Deno.test("NL-HFINAL-008: valid semantic no-action remains authoritative", async () => {
  const candidates = await decomposeLineConversationCandidates(
    "迎えお願いできると思う？",
    new Date("2026-09-12T00:00:00Z"),
    () => Promise.resolve('{"candidates":[]}'),
  );
  assertEquals(candidates, []);
});

Deno.test("NL-HFINAL-009: pending family request can be repaired into AI opinion", () => {
  assertEquals(linePendingFollowUpKind("依頼じゃなくてAIの意見が聞きたい"), "assistant_repair");
});

Deno.test("NL-HFINAL-010: reverse correction from AI to family stays actionable", () => {
  assertEquals(linePendingFollowUpKind("いやAIじゃなくて妻にお願いしたい"), "edit");
});

Deno.test("NL-HFINAL-011: current pending request can be cancelled colloquially", () => {
  assertEquals(linePendingFollowUpKind("やっぱり今のなしで"), "cancel");
});

Deno.test("NL-HFINAL-012: concrete pending edit is not mistaken for consultation", () => {
  assertEquals(linePendingFollowUpKind("時間だけ7時半にして"), "edit");
});
