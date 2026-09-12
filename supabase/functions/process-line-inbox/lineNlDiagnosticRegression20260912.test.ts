import { assertEquals } from "jsr:@std/assert@1";
import {
  isConversationOnlyCandidateSource,
  lineNonMutationDisposition,
  linePendingFollowUpKind,
} from "./lineConversation.ts";
import { normalizeSemanticDecomposition } from "./lineMultiIntent.ts";

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

Deno.test("v3 diagnostic advice phrasing: how-to-say variants remain conversation", () => {
  assertEquals(lineNonMutationDisposition("夫に頼むならどう言うのが自然？"), "assistant_conversation");
  assertEquals(lineNonMutationDisposition("家族にお願いする時どう言うのがいいかな"), "assistant_conversation");
  assertEquals(lineNonMutationDisposition("こういう時どう頼むのがいい？"), "assistant_conversation");
});

Deno.test("v3 diagnostic advice phrasing counterexample: direct family instruction remains actionable", () => {
  assertEquals(lineNonMutationDisposition("ママにこう言って、迎えお願いして"), null);
});

Deno.test("v3 diagnostic draft-only and notification meta: neighboring variants dominate action words", () => {
  assertEquals(lineNonMutationDisposition("通知しないで下書きだけ作って"), "assistant_conversation");
  assertEquals(lineNonMutationDisposition("まだ通知せず文案だけ考えて"), "assistant_conversation");
  assertEquals(lineNonMutationDisposition("送る前のしたがきだけつくって"), "assistant_conversation");
});

Deno.test("v3 diagnostic draft-only counterexample: explicit send after review remains actionable", () => {
  assertEquals(lineNonMutationDisposition("下書きはOK、ママに送って"), null);
});

Deno.test("v3 diagnostic ambiguous generic recipient: nearby generic requests remain fail-closed", () => {
  assertEquals(lineNonMutationDisposition("これ頼める？"), "ambiguous");
  assertEquals(lineNonMutationDisposition("それたのめる？"), "ambiguous");
  assertEquals(lineNonMutationDisposition("これ任せていい？"), "ambiguous");
});

Deno.test("v3 diagnostic ambiguous generic recipient counterexample: explicit role is actionable", () => {
  assertEquals(lineNonMutationDisposition("これママに頼める？"), null);
});

Deno.test("v3 diagnostic conditional desire: 'if okay' remains consultation until authorized", () => {
  assertEquals(lineNonMutationDisposition("もし大丈夫なら妻に頼みたい、どうかな"), "assistant_conversation");
  assertEquals(lineNonMutationDisposition("大丈夫ならパパにお願いしたいんだけど相談"), "assistant_conversation");
  assertEquals(lineNonMutationDisposition("可能そうならママに頼みたい、まだ送らないで"), "assistant_conversation");
});

Deno.test("v3 diagnostic conditional desire counterexample: explicit go-ahead is actionable", () => {
  assertEquals(lineNonMutationDisposition("大丈夫だからパパにお願いして"), null);
});

Deno.test("v3 diagnostic generic family-to-AI repair: nearby formulations repair pending action", () => {
  assertEquals(linePendingFollowUpKind("違う、相手に送るんじゃなくてAIに相談"), "assistant_repair");
  assertEquals(linePendingFollowUpKind("いや、パートナーに伝えるんじゃなくておうちノートに相談"), "assistant_repair");
  assertEquals(linePendingFollowUpKind("家族に送るのではなくAIに相談中"), "assistant_repair");
});

Deno.test("v3 diagnostic generic family-to-AI repair counterexample: AI-to-family reversal is actionable", () => {
  assertEquals(lineNonMutationDisposition("AIへの相談じゃなくて妻にお願いしたい"), null);
});

Deno.test("v3 diagnostic review discourse markers: leading filler does not turn review into share/action", () => {
  assertEquals(isConversationOnlyCandidateSource("まず言い方見て"), true);
  assertEquals(isConversationOnlyCandidateSource("ちょっと文面チェックして"), true);
  assertEquals(isConversationOnlyCandidateSource("一回その文案整えて"), true);
});

Deno.test("v3 diagnostic review discourse counterexample: explicit family action remains action", () => {
  assertEquals(isConversationOnlyCandidateSource("まずママに洗濯お願いして"), false);
});

Deno.test("fresh diagnostic polite-effect advice: indirect tone/effect questions remain conversation", () => {
  assertEquals(lineNonMutationDisposition("夫に頼む文章、どんな感じなら角が立たないと思う？"), "assistant_conversation");
  assertEquals(lineNonMutationDisposition("妻への文面、角立たない言い方にするならどう思う？"), "assistant_conversation");
  assertEquals(lineNonMutationDisposition("ママに今すぐ迎えお願いして"), null);
});

Deno.test("fresh diagnostic pre-send review: asking the assistant to inspect copy remains conversation", () => {
  assertEquals(lineNonMutationDisposition("家族に送る前に文面見てもらえる？"), "assistant_conversation");
  assertEquals(lineNonMutationDisposition("パートナーに送る前にこの文章見てもらえる？"), "assistant_conversation");
  assertEquals(lineNonMutationDisposition("家族にこの文章送って"), null);
});

Deno.test("fresh diagnostic generic recipient with discourse particle remains ambiguous", () => {
  assertEquals(lineNonMutationDisposition("これって頼める？"), "ambiguous");
  assertEquals(lineNonMutationDisposition("それってお願いできる？"), "ambiguous");
  assertEquals(lineNonMutationDisposition("これってママに頼める？"), null);
});

Deno.test("fresh diagnostic opinion repair: explicit assistant opinion supersedes pending family action", () => {
  assertEquals(linePendingFollowUpKind("依頼じゃなくて、あなたの意見が聞きたい"), "assistant_repair");
  assertEquals(linePendingFollowUpKind("お願いじゃなくて、AIの意見が聞きたい"), "assistant_repair");
  assertEquals(linePendingFollowUpKind("AIじゃなくてママにお願いしたい"), "edit");
});

Deno.test("fresh diagnostic colloquial cancel: current pending request can be withdrawn naturally", () => {
  assertEquals(linePendingFollowUpKind("やっぱ今のなしで"), "cancel");
  assertEquals(linePendingFollowUpKind("やっぱり今のお願いなし"), "cancel");
  assertEquals(linePendingFollowUpKind("時間だけ8時にして"), "edit");
});


Deno.test("independent review: scoped no-send does not swallow a separate explicit family action", () => {
  assertEquals(
    lineNonMutationDisposition("この文はまだ送らない、牛乳はパパに買ってもらって"),
    null,
  );
  assertEquals(
    lineNonMutationDisposition("これは送らないで、それとは別にママにゴミ出しお願い"),
    null,
  );
});

Deno.test("independent review: unscoped no-send still blocks an otherwise actionable request", () => {
  assertEquals(
    lineNonMutationDisposition("ママにゴミ出しお願い、でもまだ送らないで"),
    "assistant_conversation",
  );
});

Deno.test("independent review: lexical まま never invents Mama as addressee", () => {
  assertEquals(
    lineNonMutationDisposition("わがまま言って悪いけどこれお願いできる？"),
    "ambiguous",
  );
  const normalized = normalizeSemanticDecomposition(
    JSON.stringify({
      candidates: [{
        kind: "request",
        title: "これ",
        source_text: "わがまま言って悪いけどこれお願いできる？",
        scheduled_date: "2026-09-12",
        due_local_time: null,
        daypart: null,
        target_role: "mama",
        shared_message: "これをお願いできますか？",
        subtasks: [],
        context: null,
        calendar_visibility: "hidden",
        missing_fields: [],
        ambiguous_fields: [],
        confidence: 0.9,
      }],
    }),
    "わがまま言って悪いけどこれお願いできる？",
  );
  assertEquals(normalized, []);
});

Deno.test("independent review: genuine hiragana Mama role recovery remains intact", () => {
  const normalized = normalizeSemanticDecomposition(
    JSON.stringify({
      candidates: [{
        kind: "request",
        title: "お迎え",
        source_text: "ままにむかえおねがい",
        scheduled_date: "2026-09-12",
        due_local_time: null,
        daypart: null,
        target_role: "mama",
        shared_message: "お迎えをお願いできますか？",
        subtasks: [],
        context: null,
        calendar_visibility: "hidden",
        missing_fields: [],
        ambiguous_fields: [],
        confidence: 0.9,
      }],
    }),
    "ままにむかえおねがい",
  );
  assertEquals(normalized.length, 1);
  assertEquals(normalized[0].intent?.targetRole, "mama");
});
