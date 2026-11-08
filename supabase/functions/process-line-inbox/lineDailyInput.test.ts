import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { handleDailyInputPostback, inputDates, openDailyInput } from "./lineDailyInput.ts";
import type { LineMustCompleteContext } from "./lineMustComplete.ts";
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";

function fixture(sessions: unknown[] = [], tasks: unknown[] = [], readError = false, children: unknown[] = []) {
  const replies: Array<{ text: string; actions: LineQuickReplyAction[] }> = [];
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const filters: Array<[string, unknown[]]> = [];
  let table = "task_instances";
  const query = new Proxy({}, { get: (_, key) => key === "then"
    ? (resolve: (value: unknown) => void) => resolve({ data: table === "task_subtask_instances" ? children : tasks, error: readError ? { message: "OFFLINE" } : null })
    : (...args: unknown[]) => { filters.push([String(key), args]); return query; } });
  const ctx: LineMustCompleteContext = {
    actorId: "actor", householdId: "household", eventId: "input-event",
    client: {
      rpc: (name: string, args: Record<string, unknown>) => {
        calls.push({ name, args });
        return Promise.resolve({ data: name === "server_tx_complete_line_daily_task_v1" ? { title: "洗濯", revision: 8 } : { local_date: inputDates().today, sessions }, error: null });
      },
      from: (name: string) => { table = name; return query; },
    } as unknown as LineMustCompleteContext["client"],
    reply: (text, actions = []) => { replies.push({ text, actions }); return Promise.resolve(); },
  };
  return { ctx, replies, calls, filters };
}
function fields(action: LineQuickReplyAction): Record<string, string> {
  assert(action.type === "postback");
  return Object.fromEntries(new URLSearchParams(action.data));
}

Deno.test("daily input explicitly picks the morning session rather than the first result", async () => {
  const f = fixture([
    { id: "night", session_type: "pickup", status: "open", can_act: true },
    { id: "morning", session_type: "dropoff", status: "open", can_act: true, remaining_count: 4 },
  ]);
  await openDailyInput(f.ctx, "morning");
  assertStringIncludes(f.replies[0].text, inputDates().today);
  assertStringIncludes(f.replies[0].text, "朝・送り担当");
  assertStringIncludes(f.replies[0].text, "未記録 4件");
  const all = f.replies[0].actions.find((a) => a.label === "全部やった")!;
  assertEquals(fields(all).session_id, "morning");
  assert(f.replies[0].actions.some((a) => a.label === "昨日分・訂正"));
});

Deno.test("explicit morning with no eligible morning never silently answers evening", async () => {
  const f = fixture([{ id: "night", session_type: "pickup", status: "open", can_act: true }]);
  await openDailyInput(f.ctx, "morning");
  assertStringIncludes(f.replies[0].text, "回答できる家事チェックはありません");
  assert(!f.replies[0].actions.some((a) => a.label === "全部やった"));
});

Deno.test("input switch uses exact session ID and does not choose a submitted or partner session", async () => {
  const f = fixture([{ id: "mine", session_type: "pickup", status: "open", can_act: true },
    { id: "partner", session_type: "dropoff", status: "open", can_act: false }]);
  await handleDailyInputPostback(f.ctx, { action: "mc_input_open", day: inputDates().today, session_id: "partner" });
  assert(!f.replies[0].actions.some((a) => a.label === "全部やった"));
  assertEquals(f.calls.length, 1);
});

Deno.test("yesterday correction pages keep exact date and exclude unrelated partner work", async () => {
  const day = inputDates().yesterday;
  const tasks = Array.from({ length: 8 }, (_, i) => ({ id: `task-${i}`, title: `仕事${i}`, revision: 4, scheduled_date: day, status: "completed", planned_assignee_id: "actor" }));
  tasks.push({ ...tasks[0], id: "partner", title: "相手の仕事", planned_assignee_id: "partner" });
  const f = fixture([], tasks);
  await handleDailyInputPostback(f.ctx, { action: "mc_input_tasks", day, page: "1" });
  assertStringIncludes(f.replies[0].text, `${day}の記録（8件）`);
  assertStringIncludes(f.replies[0].text, "仕事6");
  assert(!f.replies[0].text.includes("相手の仕事"));
  const selected = fields(f.replies[0].actions[0]);
  assertEquals(selected.day, day);
  assertEquals(selected.task_id, "task-6");
  assert(f.filters.some(([k, args]) => k === "eq" && args[0] === "household_id" && args[1] === "household"));
  assert(f.filters.some(([k, args]) => k === "eq" && args[0] === "scheduled_date" && args[1] === day));
  assert(f.filters.some(([k, args]) => k === "is" && args[0] === "test_context_id" && args[1] === null));
});

Deno.test("recent task detail preserves revision in canonical reopen action", async () => {
  const day = inputDates().yesterday;
  const f = fixture([], [{ id: "t", title: "洗濯", status: "completed", revision: 12, planned_assignee_id: "actor" }]);
  await handleDailyInputPostback(f.ctx, { action: "mc_input_task", task_id: "t", day, revision: "12" });
  assertStringIncludes(f.replies[0].text, day);
  assertEquals(fields(f.replies[0].actions[0]), { action: "reopen_task", task_id: "t", revision: "12" });
  assertEquals(f.calls.length, 0);
});

Deno.test("stale task detail and old-day input cards do not offer a mutation", async () => {
  const f = fixture([], [{ id: "t", title: "洗濯", status: "completed", revision: 13, planned_assignee_id: "actor" }]);
  await handleDailyInputPostback(f.ctx, { action: "mc_input_task", task_id: "t", day: inputDates().yesterday, revision: "12" });
  assertStringIncludes(f.replies[0].text, "更新されています");
  assert(!f.replies[0].actions.some((a) => a.type === "postback" && a.data.includes("reopen_task")));
  await handleDailyInputPostback(f.ctx, { action: "mc_input_tasks", day: "2020-01-01", page: "0" });
  assertStringIncludes(f.replies[1].text, "日付が古く");
  assertEquals(f.calls.length, 0);
});

Deno.test("read uncertainty is never presented as empty history", async () => {
  const f = fixture([], [], true);
  await handleDailyInputPostback(f.ctx, { action: "mc_input_tasks", day: inputDates().yesterday, page: "0" });
  assertStringIncludes(f.replies[0].text, "読み込めませんでした");
  assert(!f.replies[0].text.includes("対象の作業はありません"));
});

Deno.test("could-not-do correction forwards canonical expected revision and stable event operation", async () => {
  const f = fixture();
  const data = { action: "mc_input_undo_failed", day: inputDates().yesterday, task_id: "t", revision: "7" };
  await handleDailyInputPostback(f.ctx, data);
  f.ctx.eventId = "different-retry-webhook";
  await handleDailyInputPostback(f.ctx, data);
  assertEquals(f.calls[0].name, "server_tx_undo_line_daily_failure_v1");
  assertEquals(f.calls[0].args.p_expected_revision, 7);
  assertEquals(f.calls[0].args.p_operation_id, f.calls[1].args.p_operation_id);
  assertEquals(f.calls[0].args.p_day, inputDates().yesterday);
});

Deno.test("recent open-task completion is revision and date bound even after a new webhook retry", async () => {
  const day = inputDates().yesterday;
  const f = fixture([], [{ id: "t", title: "洗濯", status: "todo", revision: 7, planned_assignee_id: "actor" }]);
  await handleDailyInputPostback(f.ctx, { action: "mc_input_task", task_id: "t", day, revision: "7" });
  const action = fields(f.replies[0].actions[0]);
  assertEquals(action.action, "mc_input_complete");
  assertEquals(action.day, day);
  assertEquals(action.revision, "7");
  await handleDailyInputPostback(f.ctx, action);
  f.ctx.eventId = "another-webhook";
  await handleDailyInputPostback(f.ctx, action);
  assertEquals(f.calls[0].name, "server_tx_complete_line_daily_task_v1");
  assertEquals(f.calls[0].args.p_expected_revision, 7);
  assertEquals(f.calls[0].args.p_day, day);
  assertEquals(f.calls[0].args.p_operation_id, f.calls[1].args.p_operation_id);
  assertEquals(fields(f.replies[1].actions[0]).revision, "8");
});

Deno.test("Codmon uses explicit sent caption and server-checked sent flag", async () => {
  const day = inputDates().today;
  const f = fixture([], [{ id: "c", title: "コドモン送信", status: "todo", revision: 3, planned_assignee_id: "actor", task_definitions: { code: "codmon_submit" } }]);
  await handleDailyInputPostback(f.ctx, { action: "mc_input_task", task_id: "c", day, revision: "3" });
  assertEquals(f.replies[0].actions[0].label, "コドモンを送信した");
  const action = fields(f.replies[0].actions[0]);
  await handleDailyInputPostback(f.ctx, action);
  assertEquals(f.calls[0].args.p_codmon_sent, true);
});

Deno.test("completed checklist offers native child correction instead of unsupported whole-task reopen", async () => {
  const day = inputDates().today;
  const f = fixture([], [{ id: "t", title: "洗濯", status: "completed", revision: 4, completion_mode: "subtasks", planned_assignee_id: "actor" }], false,
    [{ id: "child", title: "干す", is_completed: true }]);
  await handleDailyInputPostback(f.ctx, { action: "mc_input_task", task_id: "t", day, revision: "4" });
  assert(f.replies[0].actions.every((a) => a.type !== "postback" || !a.data.includes("action=reopen_task")));
  const detail = fields(f.replies[0].actions[0]);
  assertEquals(detail.action, "mc_input_children");
  await handleDailyInputPostback(f.ctx, detail);
  assertStringIncludes(f.replies[1].text, "干す");
  const uncheck = fields(f.replies[1].actions[0]);
  await handleDailyInputPostback(f.ctx, uncheck);
  assertEquals(f.calls[0].name, "server_tx_set_subtask_completion");
  assertEquals(f.calls[0].args.p_subtask_instance_id, "child");
  assertEquals(f.calls[0].args.p_completed, false);
  assertEquals(f.calls[0].args.p_expected_revision, 4);
  assert(f.filters.some(([k, args]) => k === "eq" && args[0] === "task_instance_id" && args[1] === "t"));
});

Deno.test("checklist correction refuses a changed parent revision before touching any child", async () => {
  const f = fixture([], [{ id: "t", title: "洗濯", status: "completed", revision: 5, completion_mode: "subtasks", planned_assignee_id: "actor" }], false,
    [{ id: "child", title: "干す", is_completed: true }]);
  await handleDailyInputPostback(f.ctx, { action: "mc_input_uncheck", task_id: "t", subtask_id: "child", day: inputDates().today, revision: "4" });
  assertStringIncludes(f.replies[0].text, "更新されています");
  assertEquals(f.calls.length, 0);
});
