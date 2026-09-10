import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { appendTodayDetailLinks, todayContextQuickReplies } from "./lineTodayUx.ts";

Deno.test("LINE Today adds concrete links only for relevant sections", () => {
  const text = appendTodayDetailLinks(
    "夜のおうちノート",
    {
      active_infos: [{ handover_id: "h1" }],
      tomorrow_impact: { impact_count: 2 },
    },
    "https://example.test/",
  );
  assertStringIncludes(text, "・今日の一覧 https://example.test/today");
  assertStringIncludes(text, "・引き継ぎ・共有 https://example.test/handovers");
  assertStringIncludes(text, "・明日の予定・準備 https://example.test/week");
});

Deno.test("LINE Today exposes request and required-share actions before fixed menu", () => {
  const actions = todayContextQuickReplies(
    {
      urgent_actions: [{ request_id: "r1" }],
      active_infos: [{ ack_policy: "required" }],
    },
    [{ type: "message", label: "今日", text: "今日" }],
  );
  assertEquals(actions.map((action) => action.label), ["お願いを確認", "共有を確認", "今日"]);
});

Deno.test("ordinary share does not ask for explicit acknowledgement", () => {
  const actions = todayContextQuickReplies(
    { urgent_actions: [], active_infos: [{ ack_policy: "none" }] },
    [{ type: "message", label: "今日", text: "今日" }],
  );
  assertEquals(actions.map((action) => action.label), ["今日"]);
});
