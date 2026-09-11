import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";

interface Context {
  client: SupabaseClient;
  actorId: string;
  householdId: string;
  eventId: string;
  reply: (text: string, quickReplies?: LineQuickReplyAction[]) => Promise<void>;
}

type JsonObject = Record<string, unknown>;

type AssignmentTask = {
  id: string;
  title: string;
  routinePhase: string;
  revision: number;
};

function record(value: unknown): JsonObject | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as JsonObject
    : null;
}

function records(value: unknown): JsonObject[] {
  return Array.isArray(value)
    ? value.map(record).filter((value): value is JsonObject => Boolean(value))
    : [];
}

function str(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function num(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function postback(label: string, data: string, displayText = label): LineQuickReplyAction {
  return { type: "postback", label, data, displayText };
}

function message(label: string, text = label): LineQuickReplyAction {
  return { type: "message", label, text };
}

async function deterministicOperationId(...parts: string[]): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(parts.join("|"))),
  );
  const bytes = digest.slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function phaseLabel(phase: string): string {
  if (phase === "morning") return "朝";
  if (phase === "evening") return "夜";
  return "日中";
}

export function isAssignmentDecisionText(text: string): boolean {
  return /^(担当を決める|担当未定|担当未定を確認)$/u.test(text.normalize("NFKC").trim());
}

async function partnerLabel(ctx: Context): Promise<string | null> {
  const { data } = await ctx.client
    .from("household_members")
    .select("user_id,family_role")
    .eq("household_id", ctx.householdId)
    .neq("user_id", ctx.actorId)
    .limit(1)
    .maybeSingle();
  if (!data) return null;
  if (data.family_role === "mama") return "ママ";
  if (data.family_role === "papa") return "パパ";
  return "相手";
}

async function assignmentTasks(ctx: Context): Promise<AssignmentTask[]> {
  const { data: briefData, error: briefError } = await ctx.client.rpc("server_read_daily_brief", {
    p_actor_id: ctx.actorId,
    p_local_date: null,
  });
  if (briefError) return [];
  const brief = record(briefData);
  const urgent = records(brief?.urgent_actions);
  const ids = urgent
    .filter((item) => item.kind === "assignment_needed")
    .map((item) => str(item.task_id))
    .filter((id): id is string => Boolean(id));
  if (ids.length === 0) return [];

  const { data: taskData, error: taskError } = await ctx.client
    .from("task_instances")
    .select("id,title,routine_phase,revision,assignment_mode,planned_assignee_actor_ref_id,planned_assignee_id,status")
    .eq("household_id", ctx.householdId)
    .in("id", ids)
    .is("test_context_id", null);
  if (taskError) return [];

  const byId = new Map(records(taskData).map((row) => [str(row.id), row]));
  const result: AssignmentTask[] = [];
  for (const id of ids) {
    const row = byId.get(id);
    if (!row) continue;
    const assignmentMode = str(row.assignment_mode) ?? (
      row.planned_assignee_actor_ref_id == null && row.planned_assignee_id == null
        ? "unassigned"
        : "person"
    );
    if (assignmentMode !== "unassigned" || row.status === "completed") continue;
    result.push({
      id,
      title: str(row.title) ?? "担当未定のタスク",
      routinePhase: str(row.routine_phase) ?? "other",
      revision: num(row.revision) ?? 1,
    });
  }
  return result;
}

export function buildAssignmentPrompt(
  task: AssignmentTask,
  index: number,
  total: number,
  partner: string | null,
): string {
  const partnerRule = partner
    ? `「${partner}にお願い」は、${partner}がLINEで「やる」を押すまで担当未定のままです。`
    : "相手へのお願いは、パートナー参加後に使えます。";
  return `担当を決める（${index + 1}/${total}）\n${phaseLabel(task.routinePhase)}｜${task.title}\n現在: 担当未定\n\n誰が対応しますか？\n「自分がやる」「誰でもOK」はその場で確定します。\n${partnerRule}`;
}

export async function openAssignmentDecision(
  ctx: Context,
  afterTaskId?: string,
): Promise<void> {
  const tasks = await assignmentTasks(ctx);
  if (tasks.length === 0) {
    await ctx.reply("いま担当を決める必要がある項目はありません。", [message("今日を見る", "今日")]);
    return;
  }

  let index = 0;
  if (afterTaskId) {
    const current = tasks.findIndex((task) => task.id === afterTaskId);
    if (current >= 0) index = (current + 1) % tasks.length;
  }
  const task = tasks[index];
  const partner = await partnerLabel(ctx);
  const quick: LineQuickReplyAction[] = [
    postback("自分がやる", new URLSearchParams({
      action: "mc_assign_unassigned",
      task_id: task.id,
      revision: String(task.revision),
      choice: "self",
    }).toString()),
    postback("誰でもOK", new URLSearchParams({
      action: "mc_assign_unassigned",
      task_id: task.id,
      revision: String(task.revision),
      choice: "anyone",
    }).toString()),
  ];
  if (partner) {
    quick.push(postback(`${partner}にお願い`, new URLSearchParams({
      action: "mc_assign_unassigned",
      task_id: task.id,
      revision: String(task.revision),
      choice: "partner",
    }).toString()));
  }
  if (tasks.length > 1) {
    quick.push(postback("次を見る", new URLSearchParams({
      action: "mc_assign_view",
      after_task_id: task.id,
    }).toString()));
  }
  await ctx.reply(buildAssignmentPrompt(task, index, tasks.length, partner), quick);
}

function mutationErrorText(messageText: string): string {
  if (/AGGREGATE_REVISION_CONFLICT|STALE|TASK_ASSIGNMENT_ALREADY_DECIDED|ASSIGNMENT_REQUEST_ALREADY_ACTIVE/u.test(messageText)) {
    return "この担当状態は更新されています。最新の担当未定一覧を開き直してください。";
  }
  if (/PARTNER_NOT_AVAILABLE/u.test(messageText)) {
    return "相手にお願いできる状態ではありません。パートナー参加状況を確認してください。";
  }
  return "担当を更新できませんでした。状態は変更していません。";
}

export async function handleAssignmentPostback(
  ctx: Context,
  fields: Record<string, string>,
): Promise<boolean> {
  if (fields.action === "mc_assign_view") {
    await openAssignmentDecision(ctx, fields.after_task_id);
    return true;
  }
  if (fields.action !== "mc_assign_unassigned") return false;

  const taskId = fields.task_id;
  const revision = Number(fields.revision);
  const choice = fields.choice;
  if (!taskId || !Number.isFinite(revision) || !["self", "anyone", "partner"].includes(choice)) {
    await ctx.reply("この操作を確認できませんでした。最新の「担当を決める」を開き直してください。");
    return true;
  }

  const { data: taskData } = await ctx.client
    .from("task_instances")
    .select("title")
    .eq("household_id", ctx.householdId)
    .eq("id", taskId)
    .maybeSingle();
  const title = typeof taskData?.title === "string" ? taskData.title : "この項目";
  const operationId = await deterministicOperationId(
    "line-unassigned-assignment",
    ctx.eventId,
    taskId,
    choice,
    String(revision),
  );

  if (choice === "partner") {
    const { data, error } = await ctx.client.rpc("server_tx_line_request_unassigned_task_assignment_v1", {
      p_actor_id: ctx.actorId,
      p_operation_id: operationId,
      p_task_id: taskId,
      p_expected_revision: revision,
    });
    if (error) {
      await ctx.reply(mutationErrorText(error.message ?? ""), [message("担当未定を確認", "担当を決める")]);
      return true;
    }
    const root = record(data);
    const role = str(root?.recipient_role) === "mama"
      ? "ママ"
      : str(root?.recipient_role) === "papa"
      ? "パパ"
      : "相手";
    await ctx.reply(
      `✓ 「${title}」を${role}にお願いしました。\n担当はまだ未定です。${role}がLINEで「やる」を押した時に担当が確定します。`,
      [message("お願いを確認", "お願いの返事"), message("今日を見る", "今日")],
    );
    return true;
  }

  const { error } = await ctx.client.rpc("server_tx_line_assign_unassigned_task_v1", {
    p_actor_id: ctx.actorId,
    p_operation_id: operationId,
    p_task_id: taskId,
    p_choice: choice,
    p_expected_revision: revision,
  });
  if (error) {
    await ctx.reply(mutationErrorText(error.message ?? ""), [message("担当未定を確認", "担当を決める")]);
    return true;
  }

  const resultText = choice === "self"
    ? `✓ 「${title}」の担当を自分にしました。承認は不要です。`
    : `✓ 「${title}」を「誰でもOK」にしました。実施前に誰かが「自分がやる」で担当表明します。`;
  await ctx.reply(resultText, [message("次の担当未定", "担当を決める"), message("今日を見る", "今日")]);
  return true;
}
