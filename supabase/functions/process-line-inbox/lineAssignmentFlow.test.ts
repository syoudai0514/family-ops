import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { buildAssignmentPrompt, isAssignmentDecisionText } from "./lineAssignmentFlow.ts";

Deno.test("assignment decision prompt explains when partner assignment becomes final", () => {
  const text = buildAssignmentPrompt(
    { id: "t1", title: "子どもの着替え準備", routinePhase: "morning", revision: 4 },
    0,
    3,
    "ママ",
  );
  assertStringIncludes(text, "担当を決める（1/3）");
  assertStringIncludes(text, "朝｜子どもの着替え準備");
  assertStringIncludes(text, "現在: 担当未定");
  assertStringIncludes(text, "「自分がやる」「誰でもOK」はその場で確定");
  assertStringIncludes(text, "ママがLINEで「やる」を押すまで担当未定のまま");
});

Deno.test("assignment decision command matching stays narrow", () => {
  assertEquals(isAssignmentDecisionText("担当を決める"), true);
  assertEquals(isAssignmentDecisionText("担当未定"), true);
  assertEquals(isAssignmentDecisionText("担当を勝手に変える"), false);
});
