import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import {
  formatScheduleReply,
  lineCreationStarterKind,
  menuQuickReplies,
  readOnlyLineIntent,
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
