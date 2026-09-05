import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import {
  formatScheduleReply,
  hasExplicitLineTopicSwitch,
  lineCreationStarterKind,
  menuQuickReplies,
  readOnlyLineIntent,
  shouldStartNewLineContext,
} from "./lineConversation.ts";

Deno.test("recognizes schedule/help as read-only", () => {
  assertEquals(readOnlyLineIntent("今日の予定は？"), "today");
  assertEquals(readOnlyLineIntent("明日の予定教えて"), "tomorrow");
  assertEquals(readOnlyLineIntent("今週どうなってる？"), "week");
  assertEquals(readOnlyLineIntent("何ができる？"), "menu");
  assertEquals(readOnlyLineIntent("何ができるんだっけ？"), "menu");
  assertEquals(readOnlyLineIntent("メニュー出して"), "menu");
  assertEquals(readOnlyLineIntent("明日の保険証を準備"), null);
});

Deno.test("vague creation starters enter clarification instead of help or fake task", () => {
  assertEquals(readOnlyLineIntent("明日の夜にタスクを追加したい"), null);
  assertEquals(lineCreationStarterKind("明日の夜にタスクを追加したい"), "task");
  assertEquals(lineCreationStarterKind("予定を追加したい"), "event");
  assertEquals(lineCreationStarterKind("お願いを送りたい"), "request");
  assertEquals(lineCreationStarterKind("買い物を追加したい"), "shopping");
  assertEquals(lineCreationStarterKind("明日の夜にゴミ出しをする"), null);
});

Deno.test("Q58 keeps context across the next day unless topic actually changes", () => {
  const previous = "2026-09-05T09:00:00+09:00";
  const nextDay = Date.parse("2026-09-06T11:00:00+09:00");
  assertEquals(shouldStartNewLineContext("それどうなった？", "遠足の準備", previous, nextDay), false);
  assertEquals(shouldStartNewLineContext("昨日の遠足の準備は？", "遠足の準備", previous, nextDay), false);
  assertEquals(shouldStartNewLineContext("遠足の準備をママにして", "遠足の準備", previous, nextDay), false);
});

Deno.test("Q58 explicit topic-switch wording always starts a new context", () => {
  assertEquals(hasExplicitLineTopicSwitch("別の話だけど、明日にして"), true);
  assertEquals(hasExplicitLineTopicSwitch("話変わるけど予定を追加したい"), true);
  assertEquals(hasExplicitLineTopicSwitch("別件で、お願いを送りたい"), true);
  assertEquals(hasExplicitLineTopicSwitch("それ明日にして"), false);
});

Deno.test("Q58 long gap resets only when a distinct fixed topic is clear", () => {
  const previous = "2026-09-05T09:00:00+09:00";
  const longAfter = Date.parse("2026-09-06T09:30:00+09:00");
  assertEquals(shouldStartNewLineContext("買い物を追加したい", "遠足の準備", previous, longAfter), true);
  assertEquals(shouldStartNewLineContext("それ", "遠足の準備", previous, longAfter), false);
  assertEquals(shouldStartNewLineContext("遠足の準備、明日にして", "遠足の準備", previous, longAfter), false);
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
