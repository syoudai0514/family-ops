// Re-review fix (P1-1) unit tests for the item-by-item flow's pure
// selection/message-shape logic. No live LINE/DB provider needed -- see
// routineItemFlow.ts's own header for why this split exists.
//
// Run: deno test --allow-env supabase/functions/process-line-inbox/routineItemFlow.test.ts
import {
  buildItemPromptText,
  buildItemQuickReply,
  buildStaleSessionText,
  pickNextUnfinished,
  unfinishedItems,
  type RoutineSessionItem,
} from "./routineItemFlow.ts";

// Dependency-free assertion helpers, matching this repo's existing
// convention (see _shared/gemini.test.ts, _shared/auth.test.ts).
function assertEquals<T>(actual: T, expected: T, message?: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(message ?? `assertEquals failed: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}
function assert(cond: boolean, message: string): void {
  if (!cond) throw new Error(message);
}

const ITEMS: RoutineSessionItem[] = [
  { task_instance_id: "a", title: "着替え", status: "completed", display_order: 0 },
  { task_instance_id: "b", title: "英語用品", status: "todo", display_order: 1 },
  { task_instance_id: "c", title: "上履き", status: "skipped", display_order: 2 },
  { task_instance_id: "d", title: "送り", status: "todo", display_order: 3 },
  { task_instance_id: "e", title: "予備", status: "in_progress", display_order: 4 },
];

Deno.test("unfinishedItems filters to todo/in_progress only, preserving order", () => {
  const result = unfinishedItems(ITEMS);
  assertEquals(result.map((i) => i.task_instance_id), ["b", "d", "e"]);
});

Deno.test("pickNextUnfinished with no cursor selects the first unfinished item deterministically", () => {
  const picked = pickNextUnfinished(ITEMS);
  assert(picked !== null, "expected a picked item");
  assertEquals(picked!.task_instance_id, "b");
});

Deno.test("pickNextUnfinished advances past the given cursor (次へ, no mutation semantics)", () => {
  const picked = pickNextUnfinished(ITEMS, "b");
  assertEquals(picked!.task_instance_id, "d");
});

Deno.test("pickNextUnfinished wraps around after the last unfinished item", () => {
  const picked = pickNextUnfinished(ITEMS, "e");
  assertEquals(picked!.task_instance_id, "b");
});

Deno.test("pickNextUnfinished restarts from the first item when the cursor is no longer unfinished", () => {
  // Simulates: item "a" was the cursor but got completed elsewhere (PWA)
  // between showing it and the next postback tap.
  const picked = pickNextUnfinished(ITEMS, "a");
  assertEquals(picked!.task_instance_id, "b");
});

Deno.test("pickNextUnfinished returns null once no items remain", () => {
  const allDone: RoutineSessionItem[] = [
    { task_instance_id: "a", title: "x", status: "completed" },
    { task_instance_id: "b", title: "y", status: "skipped" },
  ];
  assertEquals(pickNextUnfinished(allDone), null);
  assertEquals(pickNextUnfinished(allDone, "a"), null);
});

Deno.test("buildItemQuickReply produces exactly the four required actions with no bearer secret", () => {
  const actions = buildItemQuickReply("session-1", "task-1");
  assertEquals(actions.length, 4);
  assertEquals(actions.map((a) => a.label), ["完了", "相手が対応", "今回は不要", "次へ"]);
  for (const action of actions) {
    assertEquals(action.type, "postback");
    assert(action.data.includes("session_id=session-1"), "postback data must reference the session id");
    // Only opaque resource ids appear in postback data -- never anything
    // resembling a bearer token/secret (no long random hex/base64 blob
    // beyond the two known uuid-shaped resource ids).
    assert(!/token|secret|bearer/i.test(action.data), `postback data must not reference a secret: ${action.data}`);
  }
  assertEquals(actions[0].data, "action=routine_item&session_id=session-1&task_instance_id=task-1&value=complete");
  assertEquals(actions[1].data, "action=routine_item&session_id=session-1&task_instance_id=task-1&value=partner_handled");
  assertEquals(actions[2].data, "action=routine_item&session_id=session-1&task_instance_id=task-1&value=skip");
  assertEquals(actions[3].data, "action=routine_item_next&session_id=session-1&task_instance_id=task-1");
});

Deno.test("buildItemPromptText includes the item title and a PWA link (fallback path requirement #7)", () => {
  const text = buildItemPromptText("session-1", { task_instance_id: "b", title: "英語用品", status: "todo" });
  assert(text.includes("英語用品"), "prompt text must include the item title");
  assert(text.includes("/checkin/session-1"), "prompt text must include the PWA checkin deep link");
});

Deno.test("buildStaleSessionText links to the current session when known, else the stale one", () => {
  assert(
    buildStaleSessionText("current-id", "stale-id").includes("/checkin/current-id"),
    "expected the current session's checkin link when known",
  );
  assert(
    buildStaleSessionText(null, "stale-id").includes("/checkin/stale-id"),
    "expected the stale session's own checkin link as fallback",
  );
});
