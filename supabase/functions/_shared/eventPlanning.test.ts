import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildTemplateCandidates, parseAiEventCandidates } from "./eventPlanning.ts";

Deno.test("event template candidates stay pre-event and carry template provenance", () => {
  const candidates = buildTemplateCandidates("medical", "2026-09-20");
  assertEquals(candidates.length, 2);
  assertEquals(candidates[0].source, "template");
  assertEquals(candidates[0].scheduled_date, "2026-09-19");
  assertEquals(candidates.every((candidate) => candidate.scheduled_date <= "2026-09-20"), true);
});

Deno.test("event AI candidate parser preserves AI provenance and derives reviewed dates", () => {
  const candidates = parseAiEventCandidates(JSON.stringify({
    todo_candidates: [
      { title: "祖父母へ集合時間を共有する", offset_days: -3, reason: "家族の予定調整" },
      { title: "当日の持ち物を最終確認する", offset_days: -1, reason: "忘れ物防止" },
    ],
  }), "2026-11-22");
  assertEquals(candidates, [
    { candidate_id: "ai-1", source: "ai", title: "祖父母へ集合時間を共有する", scheduled_date: "2026-11-19", reason: "家族の予定調整" },
    { candidate_id: "ai-2", source: "ai", title: "当日の持ち物を最終確認する", scheduled_date: "2026-11-21", reason: "忘れ物防止" },
  ]);
});

Deno.test("event AI candidate parser rejects post-event or oversized output", () => {
  assertThrows(() => parseAiEventCandidates('{"todo_candidates":[{"title":"後日","offset_days":1,"reason":""}]}', "2026-09-20"), Error, "EVENT_AI_INVALID_SHAPE");
  assertThrows(() => parseAiEventCandidates(JSON.stringify({ todo_candidates: Array.from({ length: 9 }, (_, i) => ({ title: `候補${i}`, offset_days: -1, reason: "" })) }), "2026-09-20"), Error, "EVENT_AI_INVALID_SHAPE");
});
