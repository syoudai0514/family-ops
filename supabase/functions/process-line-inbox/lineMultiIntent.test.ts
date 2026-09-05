import { assertEquals } from "jsr:@std/assert@1";
import {
  activeMultiIntentCandidates,
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

Deno.test("only active and structurally complete group candidates are executable", () => {
  const active = activeMultiIntentCandidates([
    { candidate_id: "c1", kind: "task", title: "水着を準備", source_text: "水着準備", status: "draft", missing_fields: [], action_type: "task_create_once", payload: { title: "水着を準備" } },
    { candidate_id: "c2", kind: "shopping", title: "牛乳", source_text: "牛乳", status: "cancelled", missing_fields: [], action_type: "shopping_item_add", payload: { title: "牛乳" } },
  ]);
  assertEquals(active.map((candidate) => candidate.candidate_id), ["c1"]);
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
