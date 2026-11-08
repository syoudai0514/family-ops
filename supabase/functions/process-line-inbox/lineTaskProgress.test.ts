import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { completeLineSubtask, recordLineProgress, type LineTaskProgressContext } from "./lineTaskProgress.ts";
import { buildUnderstandPrompt, guardPlan, parsePlan, rejectedPartialPlanNeedsClarification, runPlan, type Action, type Plan, type PlanEffects, type Snapshot, type SnapshotTask } from "./lineUnderstand.ts";

const task: SnapshotTask = {
  ref: "y1", id: "10000000-0000-4000-8000-000000000001", title: "洗濯", date: "2026-11-07", revision: 8,
  status: "todo", code: null, who: "me", due: null,
  subtasks: [{ ref: "y1c1", id: "20000000-0000-4000-8000-000000000001", title: "回す", completed: false, required: true },
    { ref: "y1c2", id: "20000000-0000-4000-8000-000000000002", title: "干す", completed: false, required: true }],
};
const snapshot: Snapshot = {
  now: { date: "2026-11-08", time: "08:00", weekday: "日" }, me: "パパ", partner: "ママ",
  children: [], turns: [], pendingDraft: null, tasks: [], yesterdayTasks: [task], shopping: [], sharedNotes: [],
};
const partial = (): Extract<Action, { type: "complete_subtask" }> => ({
  type: "complete_subtask", ref: "y1", subtask_ref: "y1c1", by: "self", source: "洗濯を回した",
});
const progress = (): Extract<Action, { type: "record_progress" }> => ({
  type: "record_progress", ref: "y1", observed: null, done: "洗濯を回した", remaining: "干すのはまだ",
  next: null, by: "self", source: "洗濯を回した、干すのはまだ",
});
const plan = (actions: Action[]): Plan => ({ understanding: "途中の記録", reply: "了解", confidence: "high", actions });

function context(error: { message: string } | null = null) {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const operationKeys: string[][] = [];
  const ctx: LineTaskProgressContext = {
    client: { rpc: (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args }); return Promise.resolve({ data: { ok: true, revision: 9 }, error });
    } } as unknown as LineTaskProgressContext["client"],
    actorId: "30000000-0000-4000-8000-000000000001", householdId: "40000000-0000-4000-8000-000000000001",
    eventId: "event-progress", operationId: (...parts) => { operationKeys.push(parts); return Promise.resolve("50000000-0000-4000-8000-000000000001"); },
  };
  return { ctx, calls, operationKeys };
}

Deno.test("LINE partial prompt exposes child refs and exact date context without database IDs", () => {
  const prompt = buildUnderstandPrompt(snapshot, "昨日の洗濯を回した、干すのはまだ");
  assertStringIncludes(prompt, '"ref":"y1c1"');
  assertStringIncludes(prompt, "回す");
  assertEquals(prompt.includes(task.id), false);
  assertEquals(prompt.includes(task.subtasks![0].id), false);
});

Deno.test("partial actions require valid source spans, high confidence and matching child refs", () => {
  const text = "昨日の洗濯を回した、干すのはまだ";
  assertEquals(parsePlan(JSON.stringify(plan([partial()])))?.actions, [partial()]);
  assertEquals(guardPlan(plan([partial()]), snapshot, text)?.actions, [partial()]);
  assertEquals(guardPlan(plan([{ ...partial(), subtask_ref: "t8c1" }]), snapshot, text), null);
  assertEquals(guardPlan(plan([{ ...partial(), source: "干すのはまだ" }]), snapshot, text), null);
  assertEquals(guardPlan(plan([{ ...partial(), source: "洗濯を干した" }]), snapshot, text), null);
  assertEquals(guardPlan({ ...plan([partial()]), confidence: "medium" }, snapshot, text), null);
  assertEquals(guardPlan(plan([{ ...progress(), remaining: "明日取り出す" }]), snapshot, text), null);
  assertEquals(guardPlan(plan([partial()]), { ...snapshot, yesterdayTasks: [{ ...task, status: "done" }] }, text), null);
  assertEquals(guardPlan(plan([partial()]), { ...snapshot, yesterdayTasks: [{ ...task, date: "2026-10-01" }] }, text), null);
});

Deno.test("a partial report cannot also complete its parent, including erroneous whole-only model output", () => {
  const text = "洗濯を回した、干すのはまだ";
  assertEquals(guardPlan(plan([{ type: "complete_task", ref: "y1", by: "self" }, partial()]), snapshot, text)?.actions, [partial()]);
  assertEquals(guardPlan(plan([{ type: "complete_task", ref: "y1", by: "self" }]), snapshot, text), null);
});

Deno.test("LINE child completion calls only the canonical child command with parent revision and explicit performer", async () => {
  const { ctx, calls } = context();
  const parts = await completeLineSubtask(ctx, task, "y1c1", "unknown");
  assertEquals(calls.length, 1);
  assertEquals(calls[0].name, "server_tx_set_subtask_completion");
  assertEquals(calls[0].args.p_subtask_instance_id, task.subtasks![0].id);
  assertEquals(calls[0].args.p_expected_revision, 8);
  assertEquals(calls[0].args.p_completion_actor, "unknown");
  assertStringIncludes(parts[0].text, "2026-11-07 洗濯");
  assertStringIncludes(parts[0].text, "実施者は不明");
  assertStringIncludes(parts[0].text, "ほかの項目は変更していません");
});

Deno.test("progress uses the same canonical note writer, keeps original date and never implicitly shares", async () => {
  const { ctx, calls } = context();
  const parts = await recordLineProgress(ctx, task, progress());
  assertEquals(calls.length, 1);
  assertEquals(calls[0].name, "server_tx_record_task_progress");
  assertEquals(calls[0].args.p_task_id, task.id);
  assertEquals(calls[0].args.p_expected_revision, 8);
  assertEquals(calls[0].args.p_work_done_note, "洗濯を回した");
  assertEquals(calls[0].args.p_remaining_note, "干すのはまだ");
  assertEquals(calls[0].args.p_share_with_household, false);
  assertEquals(calls[0].args.p_ack_policy, "none");
  assertStringIncludes(parts[0].text, "2026-11-07 洗濯");
});

Deno.test("someone else's or unknown work is observation, not the recorder's actual work", async () => {
  for (const by of ["partner", "unknown"] as const) {
    const { ctx, calls } = context();
    await recordLineProgress(ctx, task, { ...progress(), by });
    assertEquals(calls[0].args.p_work_done_note, null);
    assertEquals(calls[0].args.p_observed_note, "洗濯を回した");
  }
});

Deno.test("stale or unknown outcomes never claim partial success or whole completion", async () => {
  const { ctx } = context({ message: "AGGREGATE_REVISION_CONFLICT" });
  assertStringIncludes((await completeLineSubtask(ctx, task, "y1c1", "self"))[0].text, "状態が変わっています");
  const broken = context();
  broken.ctx.client.rpc = () => Promise.reject(new Error("connection lost")) as unknown as ReturnType<typeof broken.ctx.client.rpc>;
  assertStringIncludes((await recordLineProgress(broken.ctx, task, progress()))[0].text, "記録結果を確認できません");
});

Deno.test("AI plan dispatches a partial operation through its adapter and sends one combined response", async () => {
  const { ctx, calls } = context();
  let sends = 0;
  const noWrite = () => Promise.resolve([]);
  const effects: PlanEffects = {
    showShopping: noWrite, markBought: noWrite, buyPart: noWrite, completeTask: () => { throw new Error("parent completion forbidden"); },
    completeSubtask: (t, ref, by) => completeLineSubtask(ctx, t, ref, by), recordProgress: (t, action) => recordLineProgress(ctx, t, action),
    couldNotDo: noWrite, cancelDraft: noWrite, showSchedule: () => Promise.resolve(), send: () => { sends++; return Promise.resolve(); },
  };
  await runPlan(plan([partial()]), snapshot, effects, "昨日の洗濯を回した、干すのはまだ");
  assertEquals(calls.map((c) => c.name), ["server_tx_set_subtask_completion"]);
  assertEquals(sends, 1);
});

Deno.test("a webhook retry keeps its operation key when the model output or parent revision changes", async () => {
  const { ctx, operationKeys } = context();
  await recordLineProgress(ctx, task, progress());
  await recordLineProgress(ctx, { ...task, revision: 9 }, { ...progress(), source: "別の読み取り結果" });
  await completeLineSubtask(ctx, { ...task, revision: 10 }, "y1c2", "partner");
  assertEquals(operationKeys, [
    ["partial", "event-progress", task.id], ["partial", "event-progress", task.id], ["partial", "event-progress", task.id],
  ]);
});

Deno.test("a rejected partial retry stays handled rather than falling through to whole completion", () => {
  const alreadyRecorded: Snapshot = { ...snapshot, yesterdayTasks: [{ ...task, revision: 9,
    subtasks: task.subtasks!.map((child, index) => ({ ...child, completed: index === 0 })) }] };
  const requested = plan([{ ...partial(), source: "洗濯した" }]);
  assertEquals(guardPlan(requested, alreadyRecorded, "洗濯した"), null);
  assertEquals(rejectedPartialPlanNeedsClarification(requested, "洗濯した"), true);
  assertEquals(rejectedPartialPlanNeedsClarification(plan([{ ...partial(), subtask_ref: "unknown" }]), "洗濯した"), true);
  assertEquals(rejectedPartialPlanNeedsClarification(null, "洗濯を回した、干すのはまだ"), true);
  assertEquals(rejectedPartialPlanNeedsClarification(null, "洗濯は全部終わった"), false);
  assertEquals(rejectedPartialPlanNeedsClarification(null, "全部やったよ？まだ残ってない？"), false);
});

Deno.test("partial proposals cannot hand the same sentence to legacy even in a mixed plan", () => {
  const legacy: Action = { type: "legacy" };
  const text = "洗濯を回した、干すのはまだ";
  assertEquals(guardPlan(plan([partial(), legacy]), snapshot, text)?.actions, [partial()]);
  assertEquals(guardPlan(plan([{ ...partial(), subtask_ref: "unknown" }, legacy]), snapshot, text), null);
  assertEquals(guardPlan(plan([legacy]), snapshot, text), null);
});
