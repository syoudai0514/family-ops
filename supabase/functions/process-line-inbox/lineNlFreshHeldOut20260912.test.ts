import { assertEquals } from "jsr:@std/assert@1";
import {
  lineNonMutationDisposition,
  linePendingFollowUpKind,
} from "./lineConversation.ts";
import { decomposeLineConversationCandidates } from "./lineMultiIntent.ts";

// Fresh held-out corpus sealed after the development/diagnostic fixes were frozen.
// If any row is used to tune implementation, this file stops being held-out and
// a new unseen corpus must be created before final acceptance.

type DispositionCase = {
  id: string;
  text: string;
  expected: "assistant_conversation" | "ambiguous" | null;
};

const DISPOSITION_CASES: DispositionCase[] = [
  { id: "NL-H2-001", text: "妻に頼む文章、どんな感じなら角立たないと思う？", expected: "assistant_conversation" },
  { id: "NL-H2-002", text: "明日の迎え、お願いするならどう頼むのがいい？", expected: "assistant_conversation" },
  { id: "NL-H2-003", text: "まだ登録しないで、言い方だけ相談したい", expected: "assistant_conversation" },
  { id: "NL-H2-004", text: "これ家族に送る前に文章見てもらえる？", expected: "assistant_conversation" },
  { id: "NL-H2-005", text: "ママに明日のゴミ出しお願いして", expected: null },
  { id: "NL-H2-006", text: "パパに牛乳買ってもらって", expected: null },
  { id: "NL-H2-007", text: "これってお願いできる？", expected: "ambiguous" },
];

for (const testCase of DISPOSITION_CASES) {
  Deno.test(`${testCase.id}: fresh held-out addressee boundary`, () => {
    assertEquals(lineNonMutationDisposition(testCase.text), testCase.expected);
  });
}

Deno.test("NL-H2-008: mixed model output retains only explicit family action", async () => {
  const text = "この言い方どう思う？それとは別にパパにゴミ出しお願い";
  const raw = JSON.stringify({
    candidates: [
      {
        kind: "request",
        title: "言い方の相談",
        source_text: "この言い方どう思う？",
        scheduled_date: "2026-09-12",
        target_role: null,
        missing_fields: [],
        ambiguous_fields: [],
        confidence: 0.91,
      },
      {
        kind: "request",
        title: "ゴミ出し",
        source_text: "パパにゴミ出しお願い",
        scheduled_date: "2026-09-12",
        target_role: "papa",
        shared_message: "ゴミ出しをお願いできますか？",
        missing_fields: [],
        ambiguous_fields: [],
        confidence: 0.94,
      },
    ],
  });
  const candidates = await decomposeLineConversationCandidates(
    text,
    new Date("2026-09-12T00:00:00Z"),
    () => Promise.resolve(raw),
  );
  assertEquals(candidates.length, 1);
  assertEquals(candidates[0].title, "ゴミ出し");
  assertEquals(candidates[0].intent?.targetRole, "papa");
});

Deno.test("NL-H2-009: valid semantic no-action stays non-mutating even when fallback could parse it", async () => {
  const candidates = await decomposeLineConversationCandidates(
    "明日の迎えお願いできそうかな？",
    new Date("2026-09-12T00:00:00Z"),
    () => Promise.resolve(JSON.stringify({ candidates: [] })),
  );
  assertEquals(candidates, []);
});

Deno.test("NL-H2-010: family-to-assistant repair wins over pending action", () => {
  assertEquals(linePendingFollowUpKind("お願いじゃなくて、あなたの意見が聞きたい"), "assistant_repair");
});

Deno.test("NL-H2-011: assistant-to-family reverse correction remains an edit/action direction", () => {
  assertEquals(linePendingFollowUpKind("いやAIじゃなくてママにお願いしたい"), "edit");
});

Deno.test("NL-H2-012: colloquial cancellation cancels the current pending action", () => {
  assertEquals(linePendingFollowUpKind("やっぱ今のお願いなしで"), "cancel");
});
