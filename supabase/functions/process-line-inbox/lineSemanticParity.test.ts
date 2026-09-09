import { assertEquals } from "jsr:@std/assert@1";
import { decomposeLineConversationCandidates } from "./lineMultiIntent.ts";

Deno.test("CF-08 single candidate retains material semantics used by LINE and PWA", async () => {
  const raw = "日曜のお迎えママお願い";
  const model = JSON.stringify({
    candidates: [{
      kind: "request",
      title: "お迎え",
      source_text: raw,
      scheduled_date: "2026-09-13",
      due_local_time: null,
      daypart: null,
      target_role: "mama",
      shared_message: "日曜のお迎えをお願いできますか？",
      subtasks: [],
      context: null,
      calendar_visibility: "hidden",
      missing_fields: [],
      ambiguous_fields: [],
      confidence: 0.96,
    }],
  });

  const candidates = await decomposeLineConversationCandidates(
    raw,
    new Date("2026-09-09T03:00:00Z"),
    () => Promise.resolve(model),
  );

  assertEquals(candidates.length, 1);
  const candidate = candidates[0];
  assertEquals({
    kind: candidate.kind,
    date: candidate.intent?.scheduledDate,
    assignee: candidate.intent?.targetRole,
    missingFields: candidate.missingFields,
    ambiguousFields: candidate.ambiguousFields,
    sourceText: candidate.sourceText,
  }, {
    kind: "request",
    date: "2026-09-13",
    assignee: "mama",
    missingFields: [],
    ambiguousFields: [],
    sourceText: raw,
  });
});
