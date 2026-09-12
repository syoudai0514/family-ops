import { assertEquals } from "jsr:@std/assert@1";
import {
  lineConversationalReplacementTitle,
  lineNonMutationDisposition,
  linePendingFollowUpKind,
} from "./lineConversation.ts";

type State = "none" | "draft" | "conversation" | "ambiguous" | "cancelled";

function applyTurn(state: State, text: string): State {
  if (state === "draft") {
    const follow = linePendingFollowUpKind(text);
    if (follow === "assistant_repair") return "conversation";
    if (follow === "cancel") return "cancelled";
    if (follow === "edit" || follow === "referent_question") return "draft";
  }

  const disposition = lineNonMutationDisposition(text);
  if (disposition === "assistant_conversation") return "conversation";
  if (disposition === "ambiguous") return "ambiguous";
  // The sequence corpus uses explicit family-action turns here. Their actual
  // candidate details are independently asserted by lineAddresseeQualityCorpus.
  return "draft";
}

type Scenario = {
  id: string;
  start: State;
  turns: Array<{ text: string; expected: State }>;
};

const SCENARIOS: Scenario[] = [
  {
    id: "NL-CTX-D001",
    start: "draft",
    turns: [{ text: "違う、あなたに聞いてる", expected: "conversation" }],
  },
  {
    id: "NL-CTX-D002",
    start: "draft",
    turns: [{ text: "妻じゃなくてAIに聞いてる", expected: "conversation" }],
  },
  {
    id: "NL-CTX-D003",
    start: "draft",
    turns: [{ text: "送ってじゃなくて相談", expected: "conversation" }],
  },
  {
    id: "NL-CTX-D004",
    start: "conversation",
    turns: [{ text: "いや、あなたじゃなくて妻にお願いしたい", expected: "draft" }],
  },
  {
    id: "NL-CTX-D005",
    start: "draft",
    turns: [
      { text: "違う、送り", expected: "draft" },
      { text: "時間だけ8時にして", expected: "draft" },
      { text: "やっぱさっきのなし", expected: "cancelled" },
    ],
  },
  {
    id: "NL-CTX-D006",
    start: "none",
    turns: [
      { text: "これお願いできる？", expected: "ambiguous" },
      { text: "ママにゴミ出しお願い", expected: "draft" },
    ],
  },
  {
    id: "NL-CTX-D007",
    start: "draft",
    turns: [
      { text: "ママじゃなくてパパにして", expected: "draft" },
      { text: "明日8時にして", expected: "draft" },
    ],
  },
  {
    id: "NL-CTX-D008",
    start: "conversation",
    turns: [
      { text: "登録せずに相談だけしたい", expected: "conversation" },
      { text: "相手には送らず文章だけ考えて", expected: "conversation" },
      { text: "じゃあママに今日の迎えお願いして", expected: "draft" },
    ],
  },
];

assertEquals(SCENARIOS.length, 8);

for (const scenario of SCENARIOS) {
  Deno.test(`${scenario.id}: multi-turn addressee/pending boundary remains coherent`, () => {
    let state = scenario.start;
    for (const turn of scenario.turns) {
      state = applyTurn(state, turn.text);
      assertEquals(state, turn.expected, `${scenario.id}: ${turn.text}`);
    }
  });
}

Deno.test("NL-CTX-D005 replacement title is extracted without treating correction as a new request", () => {
  assertEquals(linePendingFollowUpKind("違う、送り"), "edit");
  assertEquals(lineConversationalReplacementTitle("違う、送り"), "送り");
  assertEquals(linePendingFollowUpKind("時間だけ8時にして"), "edit");
  assertEquals(linePendingFollowUpKind("やっぱさっきのなし"), "cancel");
});

Deno.test("assistant repair and reverse correction are direction-sensitive", () => {
  assertEquals(linePendingFollowUpKind("妻じゃなくてAIに聞いてる"), "assistant_repair");
  assertEquals(linePendingFollowUpKind("送ってじゃなくて相談"), "assistant_repair");
  assertEquals(linePendingFollowUpKind("いや、あなたじゃなくて妻にお願いしたい"), "edit");
  assertEquals(lineNonMutationDisposition("いや、あなたじゃなくて妻にお願いしたい"), null);
});
