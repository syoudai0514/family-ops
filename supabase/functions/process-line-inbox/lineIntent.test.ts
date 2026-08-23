import { assertEquals } from "jsr:@std/assert@1";
import {
  deterministicLineIntent,
  isLineCreateStarter,
  normalizeGeminiLineIntent,
  toTaskSubtasks,
} from "./lineIntent.ts";

const now = new Date("2026-08-22T09:00:00Z"); // 2026-08-22 18:00 JST

Deno.test("wife dentist request becomes tomorrow-morning mama request", () => {
  const intent = deterministicLineIntent(
    "嫁さん、明日の朝、歯医者のよやくしてほしいんだけど！",
    now,
  );
  assertEquals(intent?.kind, "request");
  assertEquals(intent?.title, "歯医者の予約");
  assertEquals(intent?.scheduledDate, "2026-08-23");
  assertEquals(intent?.daypart, "morning");
  assertEquals(intent?.targetRole, "mama");
});

Deno.test("tonight preparation keeps action date today, not tomorrow hospital context", () => {
  const intent = deterministicLineIntent(
    "今日の夜に明日の病院の保険証の準備しなくちゃいけないので、パパのタスクとして追加しておいて",
    now,
  );
  assertEquals(intent?.kind, "task");
  assertEquals(intent?.title, "病院の保険証を準備");
  assertEquals(intent?.scheduledDate, "2026-08-22");
  assertEquals(intent?.daypart, "night");
  assertEquals(intent?.targetRole, "papa");
});

Deno.test("a role mention without request wording stays a task", () => {
  const intent = deterministicLineIntent(
    "明日の朝、歯医者の予約して、パパのタスクとして追加",
    now,
  );
  assertEquals(intent?.kind, "task");
  assertEquals(intent?.targetRole, "papa");
});

Deno.test("a LINE correction selects the replacement family role, not the role being replaced", () => {
  const intent = deterministicLineIntent(
    "ママじゃなくてパパに明日の保険証の準備をしてもらう",
    now,
  );
  assertEquals(intent?.targetRole, "papa");
});

Deno.test("simple shopping remains structurally parseable", () => {
  const intent = deterministicLineIntent("明日オムツをAmazonで買って", now);
  assertEquals(intent?.kind, "shopping");
  assertEquals(intent?.scheduledDate, "2026-08-23");
});

Deno.test("generic add starters are guidance, not placeholder tasks", () => {
  assertEquals(isLineCreateStarter("明日の夜にタスクを追加したい"), true);
  assertEquals(isLineCreateStarter("ママに明日の朝のお願いを送りたい"), true);
  assertEquals(isLineCreateStarter("買い物を追加したい"), true);
  assertEquals(isLineCreateStarter("予定を追加したい"), true);
  assertEquals(isLineCreateStarter("明日の夜にゴミ出しをする"), false);
  assertEquals(
    isLineCreateStarter("ママに明日の朝、歯医者の予約をお願い"),
    false,
  );
});

Deno.test("Gemini response separates a hospital preparation task from its appointment context", () => {
  const intent = normalizeGeminiLineIntent(JSON.stringify({
    kind: "task",
    title: "皮膚科の準備",
    scheduled_date: "2026-08-23",
    due_local_time: "10:00",
    daypart: null,
    target_role: null,
    shared_message: null,
    subtasks: ["子供の身支度", "診察カード", "保険証"],
    context: "藤沢の皮膚科 11:00",
    calendar_visibility: "special",
  }));

  assertEquals(intent?.title, "皮膚科の準備");
  assertEquals(intent?.scheduledDate, "2026-08-23");
  assertEquals(intent?.dueLocalTime, "10:00");
  assertEquals(intent?.subtasks, ["子供の身支度", "診察カード", "保険証"]);
  assertEquals(intent?.context, "藤沢の皮膚科 11:00");
  assertEquals(intent?.calendarVisibility, "special");
});

Deno.test("Gemini response rejects invalid dates, times, and non-request partner messages", () => {
  assertEquals(
    normalizeGeminiLineIntent(
      '{"kind":"task","title":"準備","scheduled_date":"2026-02-30","due_local_time":"10:00","shared_message":null}',
    ),
    null,
  );
  assertEquals(
    normalizeGeminiLineIntent(
      '{"kind":"task","title":"準備","scheduled_date":"2026-08-23","due_local_time":"25:00","shared_message":null}',
    ),
    null,
  );
  assertEquals(
    normalizeGeminiLineIntent(
      '{"kind":"task","title":"準備","scheduled_date":"2026-08-23","due_local_time":null,"shared_message":"相手に送る文"}',
    ),
    null,
  );
});

Deno.test("structured checklist becomes ordered canonical task subtasks on confirmation", () => {
  assertEquals(toTaskSubtasks(["子供の身支度", "診察カード", "保険証"]), [
    { title: "子供の身支度", required: true, sort_order: 1 },
    { title: "診察カード", required: true, sort_order: 2 },
    { title: "保険証", required: true, sort_order: 3 },
  ]);
  assertEquals(toTaskSubtasks(["保険証", "保険証", "", 7]), [
    { title: "保険証", required: true, sort_order: 1 },
  ]);
});
