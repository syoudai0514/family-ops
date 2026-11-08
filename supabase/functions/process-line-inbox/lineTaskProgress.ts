// LINE is a thin adapter over the same child-completion and progress commands
// used by the authenticated task screen. Model refs never become database IDs.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { recordTaskProgress } from "../_shared/taskProgress.ts";
import type { Action, ReplyPart, SnapshotTask } from "./lineUnderstand.ts";

export interface LineTaskProgressContext {
  client: SupabaseClient;
  actorId: string;
  householdId: string;
  eventId: string;
  operationId: (...parts: string[]) => Promise<string>;
}

function taskLabel(task: SnapshotTask): string {
  return `${task.date ? `${task.date} ` : ""}${task.title}`;
}

function failure(error: unknown): ReplyPart[] {
  const code = error && typeof error === "object" && "code" in error ? String(error.code)
    : error instanceof Error ? error.message
    : error && typeof error === "object" && "message" in error ? String(error.message) : "";
  if (/STALE|REVISION|CONFLICT|TERMINAL|CROSS_HOUSEHOLD|ACTOR_SCOPE/.test(code)) {
    return [{ text: "作業の状態が変わっています。「今日」または「昨日の作業」で最新の内容を確認してから、もう一度送ってください。" }];
  }
  // Transport failure after dispatch is not proof that the transaction failed.
  return [{ text: "記録結果を確認できませんでした。「今日」または「昨日の作業」で最新の状態を確認してください。" }];
}

export async function completeLineSubtask(
  ctx: LineTaskProgressContext,
  task: SnapshotTask,
  subtaskRef: string,
  by: "self" | "partner" | "unknown",
): Promise<ReplyPart[]> {
  const child = task.subtasks?.find((item) => item.ref === subtaskRef);
  if (!child || !Number.isSafeInteger(task.revision) || Number(task.revision) < 1) {
    return [{ text: "チェック項目を特定できませんでした。どの作業の、どの項目を済ませたか教えてください。" }];
  }
  try {
    // Stable for redelivery even if the model or latest task revision changes.
    // A changed payload conflicts with the existing receipt instead of writing twice.
    const operationId = await ctx.operationId("partial", ctx.eventId, task.id);
    const { error } = await ctx.client.rpc("server_tx_set_subtask_completion", {
      p_actor_id: ctx.actorId,
      p_operation_id: operationId,
      p_subtask_instance_id: child.id,
      p_completed: true,
      p_completion_actor: by,
      p_expected_revision: task.revision,
    });
    if (error) return failure(error);
    const performer = by === "unknown" ? "（実施者は不明として記録）" : by === "partner" ? "（相手が実施）" : "";
    return [{ text: `✓ ${taskLabel(task)}：${child.title}を記録しました${performer}。ほかの項目は変更していません。` }];
  } catch (error) {
    return failure(error);
  }
}

export async function recordLineProgress(
  ctx: LineTaskProgressContext,
  task: SnapshotTask,
  action: Extract<Action, { type: "record_progress" }>,
): Promise<ReplyPart[]> {
  if (!Number.isSafeInteger(task.revision) || Number(task.revision) < 1) {
    return [{ text: "作業の状態を確認できませんでした。最新の作業を開いてから、もう一度送ってください。" }];
  }
  // The canonical progress command attributes work_done to its recorder. Other
  // people's work and unknown performers are observations, never own actuals.
  const ownWork = action.by === "self" ? action.done : null;
  const observed = [action.observed, action.by !== "self" ? action.done : null].filter(Boolean).join("\n") || null;
  try {
    // Stable for redelivery even if the model or latest task revision changes.
    // A changed payload conflicts with the existing receipt instead of writing twice.
    const operationId = await ctx.operationId("partial", ctx.eventId, task.id);
    await recordTaskProgress(ctx.client, ctx.actorId, operationId, {
      task_id: task.id,
      expected_revision: task.revision,
      observed_note: observed,
      work_done_note: ownWork,
      remaining_note: action.remaining,
      next_step_note: action.next,
      share_with_household: false,
      ack_policy: "none",
    });
    const notes = [observed ? `状況：${observed}` : null, ownWork ? `行ったこと：${ownWork}` : null,
      action.remaining ? `残り：${action.remaining}` : null, action.next ? `次に必要なこと：${action.next}` : null].filter(Boolean);
    return [{ text: `✓ ${taskLabel(task)}の途中状況を記録しました。\n${notes.join("\n")}\n作業の完了や相手への送信は行っていません。` }];
  } catch (error) {
    return failure(error);
  }
}
