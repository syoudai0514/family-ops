// Re-review fix (P1-1/P1-2) unit tests for the top-level routine
// quick-reply button set.
//
// Run: deno test --allow-env supabase/functions/send-notifications/routineQuickReply.test.ts
import { buildRoutineQuickReply } from "./routineQuickReply.ts";

function assertEquals<T>(actual: T, expected: T, message?: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(message ?? `assertEquals failed: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}
function assert(cond: boolean, message: string): void {
  if (!cond) throw new Error(message);
}

Deno.test("buildRoutineQuickReply returns undefined for zero or multiple distinct sessions", () => {
  assertEquals(buildRoutineQuickReply([]), undefined);
  assertEquals(buildRoutineQuickReply(["a", "b"]), undefined);
});

Deno.test("buildRoutineQuickReply exposes all four normative top-level actions in order", () => {
  const actions = buildRoutineQuickReply(["session-1"]);
  assert(actions !== undefined, "expected quick-reply actions for exactly one session");
  assertEquals(actions!.map((a) => a.label), ["全部完了", "項目ごとに入力", "今回は不要", "PWAで開く"]);
});

Deno.test("全部完了 posts the existing complete_all postback contract unchanged", () => {
  const actions = buildRoutineQuickReply(["session-1"])!;
  assertEquals(actions[0].type, "postback");
  assertEquals((actions[0] as { data: string }).data, "action=routine_complete&session_id=session-1&value=complete_all");
});

Deno.test("項目ごとに入力 posts the new item-by-item start action, not a direct mutation", () => {
  const actions = buildRoutineQuickReply(["session-1"])!;
  assertEquals(actions[1].type, "postback");
  assertEquals((actions[1] as { data: string }).data, "action=routine_item_mode&session_id=session-1");
});

Deno.test("今回は不要 posts a confirmation-prompt action, never the direct skip_incomplete mutation (P1-2)", () => {
  const actions = buildRoutineQuickReply(["session-1"])!;
  assertEquals(actions[2].type, "postback");
  const data = (actions[2] as { data: string }).data;
  assertEquals(data, "action=routine_skip_prompt&session_id=session-1");
  assert(!data.includes("skip_incomplete"), "the first tap must never carry the mass-skip mutation value directly");
});

Deno.test("PWAで開く is a uri action pointing at the checkin deep link", () => {
  const actions = buildRoutineQuickReply(["session-1"])!;
  assertEquals(actions[3].type, "uri");
  assert((actions[3] as { uri: string }).uri.includes("/checkin/session-1"), "expected the session's checkin link");
});
