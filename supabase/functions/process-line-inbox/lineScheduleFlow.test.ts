import { assert, assertEquals, assertRejects, assertStringIncludes } from "jsr:@std/assert@1";
import { createClient } from "npm:@supabase/supabase-js@2";
import { loadLineSchedulePage } from "./lineScheduleFlow.ts";
import { clipScheduleText, parseLineSchedulePage, schedulePageData } from "./lineSchedulePage.ts";
import { buildScheduleSummaryFlex } from "./lineUxBuilders.ts";

type Json = Record<string, unknown>;

function actions(value: unknown): Json[] {
  if (Array.isArray(value)) return value.flatMap(actions);
  if (!value || typeof value !== "object") return [];
  const item = value as Json;
  return [...(item.action && typeof item.action === "object" ? [item.action as Json] : []), ...Object.values(item).flatMap(actions)];
}
function strings(value: unknown): string[] {
  if (typeof value === "string") return [value];
  if (!value || typeof value !== "object") return [];
  return Object.values(value).flatMap(strings);
}

Deno.test("schedule pages validate absolute real dates and at most seven inclusive days", () => {
  const fields = { action: "schedule_page", start: "2026-11-08", end: "2026-11-14", page: "2" };
  assertEquals(parseLineSchedulePage(fields), { startDate: "2026-11-08", endDate: "2026-11-14", page: 2 });
  for (const changes of [
    { action: "confirm_pending" }, { start: "2026-02-30" }, { end: "2026-11-15" },
    { end: "2026-11-07" }, { start: "明日" }, { page: "-1" }, { page: "1.2" }, { page: "Infinity" },
  ]) assertEquals(parseLineSchedulePage({ ...fields, ...changes }), null);
  assertEquals(parseLineSchedulePage({ ...fields, start: "2028-02-29", end: "2028-02-29", page: "0" })?.startDate, "2028-02-29");
});

Deno.test("schedule continuation preserves original dates after the calendar day changes", () => {
  const range = { startDate: "2026-11-08", endDate: "2026-11-14", page: 0 };
  const postback = Object.fromEntries(new URLSearchParams(schedulePageData(range, 3)));
  assertEquals(parseLineSchedulePage(postback), { ...range, page: 3 });
  assert(!JSON.stringify(postback).includes("tomorrow"));
});

Deno.test("schedule cards expose every page and concrete original-day details", () => {
  const entries = Array.from({ length: 14 }, (_, n) => ({ title: `予定${String(n + 1).padStart(2, "0")}`, startsAt: `2026-11-${n < 7 ? "08" : "09"}T${String(8 + n % 7).padStart(2, "0")}:00:00+09:00` }));
  const range = { startDate: "2026-11-08", endDate: "2026-11-14", page: 0 };
  const first = buildScheduleSummaryFlex("指定週", entries, "https://family.example/", range);
  assertStringIncludes(JSON.stringify(first), "予定06");
  assert(!JSON.stringify(first).includes("予定07"));
  assert(actions(first).some((action) => action.type === "postback" && action.label === "続きの予定"));
  assert(actions(first).some((action) => action.uri === "https://family.example/month?date=2026-11-08"));
  const middle = buildScheduleSummaryFlex("指定週", entries, "https://family.example", { ...range, page: 1 });
  assertStringIncludes(JSON.stringify(middle), "予定07");
  assertStringIncludes(JSON.stringify(middle), "予定12");
  assertStringIncludes(JSON.stringify(middle), "11/9");
  assert(actions(middle).some((action) => action.label === "前の予定"));
  assert(actions(middle).some((action) => action.label === "続きの予定"));
  const last = buildScheduleSummaryFlex("指定週", entries, "", { ...range, page: 999 });
  assertStringIncludes(JSON.stringify(last), "予定14");
  assert(!actions(last).some((action) => action.label === "続きの予定"));
  assert(!actions(last).some((action) => action.type === "uri"));
});

Deno.test("schedule cards fit LINE UTF-16 and bubble byte limits with long emoji names", () => {
  const emoji = "家族👨‍👩‍👧‍👦".repeat(500);
  const card = buildScheduleSummaryFlex(emoji, Array.from({ length: 6 }, () => ({ title: emoji, startsAt: "2026-11-08T08:00:00+09:00" })), "https://family.example", { startDate: "2026-11-08", endDate: "2026-11-08", page: 0 });
  assert(String(card.altText).length <= 400);
  assert(new TextEncoder().encode(JSON.stringify(card.contents)).length < 30_000);
  for (const value of strings(card)) {
    assert(!/[\uD800-\uDBFF]$/u.test(value), "unpaired high surrogate at string end");
    assert(value.length <= 2000);
  }
  assertStringIncludes(JSON.stringify(card), "長い予定名を省略");
  assertEquals(clipScheduleText("🚃🚃🚃", 4), "🚃…");
});

function mockSchedule() {
  let version = 1;
  let fail = false;
  const calls: Array<{ path: string; body: Json; search: URLSearchParams }> = [];
  const client = createClient("https://schedule-test.supabase.co", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { fetch: (input, init) => {
      const url = new URL(input instanceof Request ? input.url : String(input));
      const body = JSON.parse(String(init?.body ?? "{}")) as Json;
      calls.push({ path: url.pathname, body, search: url.searchParams });
      if (url.pathname.endsWith("/rpc/server_tx_get_week_schedule")) {
        if (fail) return Promise.resolve(Response.json({ message: "TEMPORARY_READ_FAILURE", code: "P0001" }, { status: 400 }));
        return Promise.resolve(Response.json({ assignments: Array.from({ length: version === 1 ? 8 : 1 }, (_, n) => ({
          task_instance_id: `task-${n}`, title: `作業${n + 1}-v${version}`, due_at: `2026-11-08T${String(8 + n).padStart(2, "0")}:00:00+09:00`, planned_assignee_id: "mama",
        })), occurrences: [{ title: `Google-v${version}`, starts_at: "2026-11-08T07:00:00+09:00" }] }));
      }
      if (url.pathname.endsWith("/household_members")) return Promise.resolve(Response.json([{ user_id: "mama", family_role: "mama" }]));
      throw new Error(`Unexpected request: ${url.pathname}`);
    } },
  });
  return { client, calls, update: () => { version = 2; }, fail: () => { fail = true; } };
}

Deno.test("schedule next-page handler reads resolved actor and household afresh over Data API", async () => {
  const mock = mockSchedule();
  const args = { client: mock.client, actorId: "papa", householdId: "family", startDate: "2026-11-08", endDate: "2026-11-08", appBaseUrl: "https://family.example" };
  const initial = await loadLineSchedulePage(args);
  assertStringIncludes(initial.text, "1/2ページ");
  assertStringIncludes(initial.text, "Google-v1");
  const next = actions(initial.message).find((action) => action.label === "続きの予定");
  assert(next?.type === "postback");
  const range = parseLineSchedulePage(Object.fromEntries(new URLSearchParams(String(next.data))));
  assert(range);
  const second = await loadLineSchedulePage({ ...args, ...range });
  assertStringIncludes(second.text, "2/2ページ");
  assertStringIncludes(second.text, "作業8-v1");
  assert(!second.text.includes("作業1-v1"));
  mock.update();
  const refreshed = await loadLineSchedulePage({ ...args, ...range });
  assertStringIncludes(refreshed.text, "1/1ページ");
  assertStringIncludes(refreshed.text, "作業1-v2");
  assert(!refreshed.text.includes("作業8-v1"));
  const rpcCalls = mock.calls.filter((call) => call.path.includes("/rpc/"));
  assertEquals(rpcCalls.length, 3);
  for (const call of rpcCalls) assertEquals(call.body, { p_actor_id: "papa", p_start_date: "2026-11-08", p_end_date: "2026-11-08" });
  for (const call of mock.calls.filter((call) => call.path.endsWith("/household_members"))) assertEquals(call.search.get("household_id"), "eq.family");
});

Deno.test("schedule read failures never masquerade as an empty calendar", async () => {
  const mock = mockSchedule();
  mock.fail();
  await assertRejects(() => loadLineSchedulePage({ client: mock.client, actorId: "papa", householdId: "family", startDate: "2026-11-08", endDate: "2026-11-08", appBaseUrl: "" }), Error, "TEMPORARY_READ_FAILURE");
});

Deno.test("invalid schedule page performs no database calls and empty pages retain reload", async () => {
  const mock = mockSchedule();
  await assertRejects(() => loadLineSchedulePage({ client: mock.client, actorId: "papa", householdId: "family", startDate: "2026-02-31", endDate: "2026-02-31", appBaseUrl: "" }), Error, "INVALID_LINE_SCHEDULE_RANGE");
  assertEquals(mock.calls.length, 0);
  const empty = buildScheduleSummaryFlex("指定日", [], "", { startDate: "2026-11-08", endDate: "2026-11-08", page: 0 });
  assertStringIncludes(JSON.stringify(empty), "予定はありません。");
  assert(actions(empty).some((action) => action.label === "最新を表示"));
});
