import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import type { SavedTaskCorrectionContext } from "./lineSavedTaskCorrection.ts";
import { openSavedTaskCorrection, parseSavedTaskDatetime, tryHandleSavedTaskCorrectionPostback } from "./lineSavedTaskCorrection.ts";
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";

const pending = "a0000000-0000-4000-8000-000000000001";
const task = "a0000000-0000-4000-8000-000000000002";
const household = "a0000000-0000-4000-8000-000000000003";
const actor = "a0000000-0000-4000-8000-000000000004";
const row = { pending_action_id: pending, task_id: task, household_id: household, title: "ごみ出し",
  scheduled_date: "2026-11-08", due_at: "2026-11-07T23:00:00.000Z", status: "todo", revision: 3,
  can_reschedule: true, can_reopen: false };

function context(handler: (name: string, args: Record<string, unknown>) => unknown) {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const replies: Array<{ text: string; quick: LineQuickReplyAction[] }> = [];
  const ctx: SavedTaskCorrectionContext = { client: { rpc(name: string, args: Record<string, unknown>) {
    calls.push({ name, args }); return Promise.resolve(handler(name, args));
  } } as unknown as SavedTaskCorrectionContext["client"], actorId: actor, householdId: household,
    eventId: "event1", reply(text, quick = []) { replies.push({ text, quick }); return Promise.resolve(); } };
  return { ctx, calls, replies };
}

function postback(quick: LineQuickReplyAction) {
  assert(quick.type === "postback");
  return Object.fromEntries(new URLSearchParams(quick.data));
}

Deno.test("saved correction picker dates are strict JST and reject invalid local calendar dates", () => {
  assertEquals(parseSavedTaskDatetime("2026-11-09T08:30"), "2026-11-08T23:30:00.000Z");
  for (const value of [undefined, "2026-02-30T08:30", "2026-11-09T24:30", "2026-11-09T08:30Z", "yesterday"]) {
    assertEquals(parseSavedTaskDatetime(value), null);
  }
});

Deno.test("saved task correction selects persisted target, previews picker change, and only writes on explicit button", async () => {
  const { ctx, calls, replies } = context((name, args) => name === "server_read_line_saved_task_v1"
    ? { data: row, error: null } : { data: { ...row, ok: true, action: args.p_action,
      scheduled_date: "2026-11-09", due_at: "2026-11-08T23:30:00+00:00", revision: 4 }, error: null });
  await openSavedTaskCorrection(ctx, pending);
  const picker = replies[0].quick[0];
  assert(picker.type === "datetimepicker");
  assertEquals(picker.initial, "2026-11-08T08:00");
  const selection = { ...Object.fromEntries(new URLSearchParams(picker.data)), datetime: "2026-11-09T08:30" };
  assertEquals(await tryHandleSavedTaskCorrectionPostback(ctx, selection), true);
  assertEquals(calls.every((call) => call.name === "server_read_line_saved_task_v1"), true);
  assertStringIncludes(replies[1].text, "まだ変更していません");
  const confirm = postback(replies[1].quick[0]);
  assertEquals(confirm.due, "2026-11-09T08:30");
  await tryHandleSavedTaskCorrectionPostback(ctx, confirm);
  const write = calls.at(-1)!;
  assertEquals(write.name, "server_tx_correct_line_saved_task_v1");
  assertEquals(write.args.p_actor_id, actor);
  assertEquals(write.args.p_pending_action_id, pending);
  assertEquals(write.args.p_expected_revision, 3);
  assertEquals(write.args.p_new_due_at, "2026-11-08T23:30:00.000Z");
  assertStringIncludes(replies[2].text, "日時を変更しました");
});

Deno.test("stale picker or cross-household read cannot write, and latest target remains reachable", async () => {
  const { ctx, calls, replies } = context(() => ({ data: { ...row, revision: 4 }, error: null }));
  await tryHandleSavedTaskCorrectionPostback(ctx, { action: "lst_reschedule", pending_action_id: pending, revision: "3", datetime: "2026-11-09T08:30" });
  assertStringIncludes(replies[0].text, "更新されています");
  assertEquals(postback(replies[0].quick[0]).pending_action_id, pending);
  assertEquals(calls.length, 1);
  const foreign = context(() => ({ data: { ...row, household_id: task }, error: null }));
  await openSavedTaskCorrection(foreign.ctx, pending);
  assertStringIncludes(foreign.replies[0].text, "安全に確認できない");
  assertEquals(foreign.replies[0].quick.some((quick) => quick.type === "datetimepicker"), false);
});

Deno.test("unknown save result exposes same operation retry across different events", async () => {
  const { ctx, calls, replies } = context(() => ({ data: null, error: { message: "network timeout" } }));
  const input = { action: "lst_apply", pending_action_id: pending, revision: "3", due: "2026-11-09T08:30" };
  await tryHandleSavedTaskCorrectionPostback(ctx, input);
  assertStringIncludes(replies[0].text, "保存結果を確認できません");
  const retry = postback(replies[0].quick[0]);
  ctx.eventId = "event2";
  await tryHandleSavedTaskCorrectionPostback(ctx, retry);
  assertEquals(calls[0].args.p_operation_id, calls[1].args.p_operation_id);
  assertEquals(calls[0].args, calls[1].args);
});

Deno.test("saved whole-task reopen requires an explicit confirmation; no cancel/delete interpretation", async () => {
  const { ctx, calls, replies } = context((name) => name === "server_read_line_saved_task_v1"
    ? { data: { ...row, status: "completed", can_reschedule: false, can_reopen: true }, error: null }
    : { data: { ...row, ok: true, status: "todo", action: "reopen", revision: 4 }, error: null });
  await openSavedTaskCorrection(ctx, pending);
  await tryHandleSavedTaskCorrectionPostback(ctx, postback(replies[0].quick[0]));
  assertEquals(calls.length, 2);
  assertStringIncludes(replies[1].text, "履歴は残ります");
  await tryHandleSavedTaskCorrectionPostback(ctx, postback(replies[1].quick[0]));
  assertEquals(calls.at(-1)?.args.p_action, "reopen");
  assertEquals(calls.at(-1)?.args.p_new_due_at, null);
  assertStringIncludes(replies[2].text, "未完了");
});
