import { buildItemPromptText, buildItemQuickReply, buildStaleSessionText, pickNextUnfinished, type RoutineSessionItem, unfinishedItems } from "./routineItemFlow.ts";

function assertEquals<T>(actual: T, expected: T, message?: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(message ?? `assertEquals failed: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
function assert(cond: boolean, message: string): void { if (!cond) throw new Error(message); }

const ITEMS: RoutineSessionItem[] = [
  { task_instance_id: "a", title: "着替え", status: "completed", display_order: 0 },
  { task_instance_id: "b", title: "英語用品", status: "todo", display_order: 1 },
  { task_instance_id: "c", title: "上履き", status: "skipped", display_order: 2 },
  { task_instance_id: "d", title: "送り", status: "todo", display_order: 3 },
  { task_instance_id: "e", title: "予備", status: "in_progress", display_order: 4 },
];

Deno.test("unfinishedItems filters to todo/in_progress only, preserving order", () => assertEquals(unfinishedItems(ITEMS).map((i) => i.task_instance_id), ["b", "d", "e"]));
Deno.test("pickNextUnfinished selects, advances, wraps, and safely restarts", () => {
  assertEquals(pickNextUnfinished(ITEMS)?.task_instance_id, "b");
  assertEquals(pickNextUnfinished(ITEMS, "b")?.task_instance_id, "d");
  assertEquals(pickNextUnfinished(ITEMS, "e")?.task_instance_id, "b");
  assertEquals(pickNextUnfinished(ITEMS, "a")?.task_instance_id, "b");
});
Deno.test("pickNextUnfinished returns null once no unfinished items remain", () => assertEquals(pickNextUnfinished([{ task_instance_id: "a", title: "x", status: "completed" }]), null));

Deno.test("Q64 LINE item menu exposes all seven canonical outcomes plus non-mutating next", () => {
  const actions = buildItemQuickReply("session-1", "task-1");
  assertEquals(actions.length, 8);
  assertEquals(actions.map((a) => a.label), ["完了", "相手が対応", "できなかった", "今回は不要", "中止", "明日に再予定", "不明", "次へ"]);
  assertEquals(actions.slice(0, 7).map((a) => new URLSearchParams(a.data).get("value")), ["complete", "partner_handled", "failed", "skip", "cancelled", "rescheduled", "unknown"]);
  assertEquals(actions[7].data, "action=routine_item_next&session_id=session-1&task_instance_id=task-1");
  for (const action of actions) {
    assert(action.data.includes("session_id=session-1"), "postback must reference the session");
    assert(!/token|secret|bearer/i.test(action.data), `postback must not carry a secret: ${action.data}`);
  }
});

Deno.test("buildItemPromptText keeps PWA fallback", () => {
  const text = buildItemPromptText("session-1", { task_instance_id: "b", title: "英語用品", status: "todo" });
  assert(text.includes("英語用品"), "prompt must include title");
  assert(text.includes("/checkin/session-1"), "prompt must include PWA checkin link");
});
Deno.test("buildStaleSessionText uses current safe session when available", () => {
  assert(buildStaleSessionText("current-id", "stale-id").includes("/checkin/current-id"), "expected current link");
  assert(buildStaleSessionText(null, "stale-id").includes("/checkin/stale-id"), "expected fallback link");
});
