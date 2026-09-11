import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import {
  formatScheduleReply,
  isAssistantAddressCorrection,
  isLineCorrectionCue,
  lineCreationStarterKind,
  lineLinkWelcomeText,
  menuQuickReplies,
  readOnlyLineIntent,
} from "./lineConversation.ts";

Deno.test("recognizes schedule/help as read-only", () => {
  assertEquals(readOnlyLineIntent("今日"), "today");
  assertEquals(readOnlyLineIntent("明日"), "tomorrow");
  assertEquals(readOnlyLineIntent("今週"), "week");
  assertEquals(readOnlyLineIntent("今日の予定は？"), "today");
  assertEquals(readOnlyLineIntent("明日の予定教えて"), "tomorrow");
  assertEquals(readOnlyLineIntent("今週どうなってる？"), "week");
  assertEquals(readOnlyLineIntent("何ができる？"), "menu");
  assertEquals(readOnlyLineIntent("何ができるんだっけ？"), "menu");
  assertEquals(readOnlyLineIntent("メニュー出して"), "menu");
  assertEquals(readOnlyLineIntent("明日の保険証を準備"), null);
});

Deno.test("real-user schedule inquiry variants never become mutation candidates", () => {
  assertEquals(readOnlyLineIntent("あしたのよていおしえて！"), "tomorrow");
  assertEquals(readOnlyLineIntent("違う違う、ただ明日の予定知りたいだけ！"), "tomorrow");
  assertEquals(readOnlyLineIntent("きょうのよてい知りたい"), "today");
  assertEquals(readOnlyLineIntent("こんしゅうのよてい見たい！"), "week");
  assertEquals(readOnlyLineIntent("明日なにある？"), "tomorrow");
  assertEquals(readOnlyLineIntent("明日の予定を追加したい"), null);
  assertEquals(readOnlyLineIntent("明日の予定を登録"), null);
  assertEquals(readOnlyLineIntent("今日なんか予定あったっけ？"), "today");
  assertEquals(readOnlyLineIntent("今日なんかかよていあったっけ？"), "today");
  assertEquals(readOnlyLineIntent("今日って何か予定ある？"), "today");
  assertEquals(readOnlyLineIntent("ちがうよ、今日の予定教えて"), "today");
  assertEquals(readOnlyLineIntent("今日の予定を追加して"), null);
});

Deno.test("conversation correction cues distinguish assistant-address repair from partner requests", () => {
  assertEquals(isLineCorrectionCue("ちがうよ、今日の予定教えて"), true);
  assertEquals(isAssistantAddressCorrection("あなたに言っているよ"), true);
  assertEquals(isAssistantAddressCorrection("おうちノートに聞いてるんだよ"), true);
  assertEquals(isAssistantAddressCorrection("ママにお願いして"), false);
});

Deno.test("LINE link success message explains what to do next", () => {
  const text = lineLinkWelcomeText();
  assertStringIncludes(text, "LINE連携が完了しました");
  assertStringIncludes(text, "今日なんか予定あったっけ？");
  assertStringIncludes(text, "お願いを送りたい");
  assertStringIncludes(text, "まずは「今日」");
});

Deno.test("vague creation starters enter clarification instead of help or fake task", () => {
  assertEquals(readOnlyLineIntent("明日の夜にタスクを追加したい"), null);
  assertEquals(lineCreationStarterKind("明日の夜にタスクを追加したい"), "task");
  assertEquals(lineCreationStarterKind("予定を追加したい"), "event");
  assertEquals(lineCreationStarterKind("お願いを送りたい"), "request");
  assertEquals(lineCreationStarterKind("買い物を追加したい"), "shopping");
  assertEquals(lineCreationStarterKind("明日の夜にゴミ出しをする"), null);
});

Deno.test("menu quick replies expose the literal six Q73 LINE entry points", () => {
  assertEquals(menuQuickReplies().map((item) => item.label), [
    "今日",
    "入力",
    "追加",
    "お願い",
    "共有",
    "その他",
  ]);
});

Deno.test("literal LINE entries route to their concrete surface", () => {
  assertEquals(readOnlyLineIntent("入力"), "input");
  assertEquals(readOnlyLineIntent("追加したい"), "add");
  assertEquals(readOnlyLineIntent("共有"), "share");
  assertEquals(readOnlyLineIntent("その他"), "other");
});

Deno.test("schedule reply remains compact", () => {
  const text = formatScheduleReply(
    "今日の予定",
    Array.from(
      { length: 9 },
      (_, index) => ({
        title: `予定${index + 1}`,
        startsAt: "2026-08-23T01:30:00Z",
        roleLabel: index === 0 ? "P" : null,
      }),
    ),
  );
  assertStringIncludes(text, "10:30 予定1（P）");
  assertStringIncludes(text, "ほか1件");
});
