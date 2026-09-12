import { assertEquals } from "jsr:@std/assert@1";
import {
  isConversationOnlyCandidateSource,
  lineNonMutationDisposition,
  linePendingFollowUpKind,
} from "./lineConversation.ts";

Deno.test("diagnostic no-send wording-only: neighboring paraphrases remain non-mutating", () => {
  assertEquals(lineNonMutationDisposition("誰にも送信せず文案だけ整えて"), "assistant_conversation");
  assertEquals(lineNonMutationDisposition("送信しないで言い方だけ考えて"), "assistant_conversation");
  assertEquals(lineNonMutationDisposition("相手に送らず文面だけ一緒に考えて"), "assistant_conversation");
});

Deno.test("diagnostic no-send wording-only: explicit later authorization remains actionable", () => {
  assertEquals(lineNonMutationDisposition("じゃあママにその文章送って"), null);
});

Deno.test("diagnostic conditional family desire: neighboring hypotheses remain conversation", () => {
  assertEquals(lineNonMutationDisposition("問題なさそうなら妻に頼みたい、どう思う？"), "assistant_conversation");
  assertEquals(lineNonMutationDisposition("できそうならパパにお願いしたいんだけど相談"), "assistant_conversation");
  assertEquals(lineNonMutationDisposition("大丈夫そうならママに頼みたい、どうかな"), "assistant_conversation");
});

Deno.test("diagnostic conditional family desire: explicit authorization remains actionable", () => {
  assertEquals(lineNonMutationDisposition("大丈夫、ママに迎えお願いして"), null);
});

Deno.test("diagnostic assistant repair: ongoing consultation variants supersede pending family action", () => {
  assertEquals(linePendingFollowUpKind("違う、AIに相談してる"), "assistant_repair");
  assertEquals(linePendingFollowUpKind("いや、おうちノートに相談している"), "assistant_repair");
  assertEquals(linePendingFollowUpKind("そうじゃなくてAIに相談中"), "assistant_repair");
});

Deno.test("diagnostic assistant repair: reverse correction to family remains an edit/action direction", () => {
  assertEquals(lineNonMutationDisposition("AIじゃなくてママに迎えお願いしたい"), null);
});

Deno.test("diagnostic wording review: review spans are conversation-only", () => {
  assertEquals(isConversationOnlyCandidateSource("この言い方見て"), true);
  assertEquals(isConversationOnlyCandidateSource("文面チェックして"), true);
  assertEquals(isConversationOnlyCandidateSource("その文案整えて"), true);
});

Deno.test("diagnostic wording review: explicit family request is not review-only", () => {
  assertEquals(isConversationOnlyCandidateSource("ママに洗濯お願いして"), false);
});
