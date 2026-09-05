import { assertEquals } from "jsr:@std/assert@1";
import {
  deterministicLineConversationCandidates,
  isMultiIntentMessage,
} from "./lineMultiIntent.ts";

Deno.test("one LINE message retains grouped share/task/shopping/request/actual candidates", () => {
  const candidates = deterministicLineConversationCandidates(
    "明日は水遊び。水着準備しとく。牛乳なくなりそう。金曜のお迎えお願い。今日は掃除機かけた。",
    new Date("2026-08-22T09:00:00Z"),
  );
  assertEquals(candidates.map((candidate) => candidate.kind), [
    "share", "task", "shopping", "request", "actual",
  ]);
  assertEquals(candidates[2].title, "牛乳");
  assertEquals(candidates[3].missingFields, ["assignee"]);
  assertEquals(isMultiIntentMessage(candidates), true);
});

Deno.test("a single candidate remains a normal preview, not a forced group", () => {
  const candidates = deterministicLineConversationCandidates(
    "明日オムツをAmazonで買って",
    new Date("2026-08-22T09:00:00Z"),
  );
  assertEquals(candidates.length, 1);
  assertEquals(candidates[0].kind, "shopping");
  assertEquals(isMultiIntentMessage(candidates), false);
});
