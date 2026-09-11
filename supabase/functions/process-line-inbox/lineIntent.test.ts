import { assertEquals } from "jsr:@std/assert@1";
import {
  deterministicLineIntent,
  extractLineIntent,
  isLineCreateStarter,
  isPickupAssignmentChangeText,
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


Deno.test("pickup assignment-change wording accepts blunt requests but not a bare recollection question", () => {
  assertEquals(isPickupAssignmentChangeText("9/14のお迎え変われ"), true);
  assertEquals(isPickupAssignmentChangeText("9/14のお迎え代わって"), true);
  assertEquals(isPickupAssignmentChangeText("9/14のお迎え交代して"), true);
  assertEquals(
    isPickupAssignmentChangeText("9/14の迎え変わってくれるって言ってたよね？よろしく"),
    true,
  );
  assertEquals(
    isPickupAssignmentChangeText("9/14の迎え変わってくれるって言ってたよね？"),
    false,
  );
  assertEquals(isPickupAssignmentChangeText("9/14のお迎え担当変わった？"), false);
});


Deno.test("shopping fallback handles terse low-stock and colloquial buy wording", () => {
  assertEquals(deterministicLineIntent("牛乳なくなった買っといて", now)?.kind, "shopping");
  assertEquals(deterministicLineIntent("牛乳なくなった買っといて", now)?.title, "牛乳");
  assertEquals(deterministicLineIntent("洗剤切れそう、帰り買って", now)?.kind, "shopping");
  assertEquals(deterministicLineIntent("洗剤切れそう、帰り買って", now)?.title, "洗剤");
});

Deno.test("shopping fallback preserves explicit quantities and role only when written", () => {
  const plain = deterministicLineIntent("明日牛乳2本買って", now);
  assertEquals(plain?.kind, "shopping");
  assertEquals(plain?.targetRole, null);
  const assigned = deterministicLineIntent("明日ママに牛乳2本買って", now);
  assertEquals(assigned?.kind, "shopping");
  assertEquals(assigned?.targetRole, "mama");
});


Deno.test("hiragana family role is recovered from colloquial pickup request", async () => {
  const got = await extractLineIntent(
    "あしたままむかえおねがい",
    now,
    () => Promise.resolve(JSON.stringify({
      kind: "request",
      title: "迎え",
      scheduled_date: "2026-09-12",
      due_local_time: null,
      daypart: null,
      target_role: null,
      shared_message: "迎えをお願いできますか？",
      subtasks: [],
      context: null,
      calendar_visibility: "hidden",
    })),
  );
  assertEquals(got?.targetRole, "mama");
  assertEquals(got?.kind, "request");
});

Deno.test("role-prefixed noun phrase without a request cue remains an assigned task", async () => {
  const got = await extractLineIntent(
    "ママ明日保険証準備",
    now,
    () => Promise.resolve(JSON.stringify({
      kind: "request",
      title: "保険証の準備",
      scheduled_date: "2026-09-12",
      due_local_time: null,
      daypart: null,
      target_role: "mama",
      shared_message: "保険証の準備をお願いできますか？",
      subtasks: [],
      context: null,
      calendar_visibility: "hidden",
    })),
  );
  assertEquals(got?.kind, "task");
  assertEquals(got?.targetRole, "mama");
  assertEquals(got?.sharedMessage, null);
});
