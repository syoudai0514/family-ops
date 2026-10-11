import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import {
  conversationalScheduleLead,
  eventCalendarChoiceReply,
  scheduleDateInquiry,
  formatScheduleReply,
  isAssistantAddressCorrection,
  isLineCorrectionCue,
  lineCreationStarterKind,
  lineLinkWelcomeText,
  menuQuickReplies,
  pendingConfirmationMessage,
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

Deno.test("natural schedule questions get a separate conversational lead while literal shortcuts stay compact", () => {
  assertEquals(conversationalScheduleLead("今日", "today"), null);
  assertEquals(
    conversationalScheduleLead("今日なんか予定あったっけ？", "today"),
    "うん、今日の予定見てみたよ！こんな感じ👇",
  );
  assertEquals(
    conversationalScheduleLead("ちがうよ、今日の予定教えて", "today", true),
    "了解。登録じゃなくて、今日の予定の確認ね。見てみたよ👇",
  );
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


Deno.test("pending confirmation copy preserves request negotiation state", () => {
  assertEquals(
    pendingConfirmationMessage("assignment_change_request"),
    "✓ お願いを送りました。\n相手の返事を待っています。担当はまだ変わっていません。",
  );
  assertEquals(
    pendingConfirmationMessage("request_create"),
    "✓ お願いを送りました。\n相手の返事を待っています。",
  );
  assertEquals(pendingConfirmationMessage("task_create_once"), "✓ 登録しました。");
});

Deno.test("an event confirmation says it goes to Google and offers a one-tap opt-out and a way back", () => {
  const on = eventCalendarChoiceReply("pa-1", "special");
  assert(on.text.includes("Googleカレンダーにも入れます"));
  assertEquals(on.quickReplies.map((q) => q.label), ["Googleに入れない"]);
  assertEquals((on.quickReplies[0] as { data: string }).data, "action=calendar_visibility&pending_action_id=pa-1&value=hidden");
  const off = eventCalendarChoiceReply("pa-1", "hidden");
  assert(off.text.includes("入れません"));
  assertEquals((off.quickReplies[0] as { data: string }).data, "action=calendar_visibility&pending_action_id=pa-1&value=special");
});

Deno.test("「10/24の予定見せて」 asks for that day's schedule; a dated entry still creates", () => {
  assertEquals(scheduleDateInquiry("10/24の予定見せて", "2026-10-11"), "2026-10-24");
  assertEquals(scheduleDateInquiry("10月24日の予定は？", "2026-10-11"), "2026-10-24");
  assertEquals(scheduleDateInquiry("10/24(土)何がある？", "2026-10-11"), "2026-10-24");
  assertEquals(scheduleDateInquiry("１/５の予定", "2026-12-20"), "2027-01-05");
  assertEquals(scheduleDateInquiry("10/17 9:00-詩乃の便秘通院。パパ担当", "2026-10-11"), null);
  assertEquals(scheduleDateInquiry("10/24に運動会の予定を追加", "2026-10-11"), null);
  assertEquals(scheduleDateInquiry("2/30の予定", "2026-10-11"), null);
});
