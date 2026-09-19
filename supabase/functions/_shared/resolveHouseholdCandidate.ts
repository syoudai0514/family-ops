import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { isPickupAssignmentChangeText } from "../process-line-inbox/lineIntent.ts";
import type { LineConversationCandidate } from "../process-line-inbox/lineMultiIntent.ts";

export type ResolvedHouseholdAction =
  | {
      type: "assignment_change_request";
      taskId: string;
      taskRevision: number;
      recipientUserId: string;
      scope: "once" | "this_week";
      scheduledDate: string;
      dueAt: string | null;
      currentAssigneeId: string | null;
    }
  | { type: "needs_clarification"; field: string; question: string }
  | null;

type ResolveInput = {
  candidate: LineConversationCandidate;
  actorId: string;
  householdId: string;
};

async function recipientForCandidate(
  client: SupabaseClient,
  householdId: string,
  actorId: string,
  targetRole: string | null | undefined,
): Promise<string | null> {
  let query = client.from("household_members").select("user_id,family_role").eq("household_id", householdId).neq("user_id", actorId);
  if (targetRole === "papa" || targetRole === "mama") query = query.eq("family_role", targetRole);
  const { data, error } = await query.limit(2);
  if (error) throw new Error(error.message);
  return data?.length === 1 ? String(data[0].user_id) : null;
}

export async function resolveHouseholdCandidate(
  client: SupabaseClient,
  input: ResolveInput,
): Promise<ResolvedHouseholdAction> {
  const { candidate, actorId, householdId } = input;
  if (candidate.kind !== "request" || !isPickupAssignmentChangeText(candidate.sourceText)) return null;

  const scheduledDate = candidate.intent?.scheduledDate;
  if (!scheduledDate) {
    return { type: "needs_clarification", field: "お迎えの日", question: "どの日のお迎えを代わってほしいか確認してください。" };
  }

  const recipientUserId = await recipientForCandidate(
    client,
    householdId,
    actorId,
    candidate.intent?.targetRole,
  );
  if (!recipientUserId) {
    return { type: "needs_clarification", field: "お願いする相手", question: "お迎えをお願いする相手を確認してください。" };
  }

  const { data: definition, error: definitionError } = await client
    .from("task_definitions")
    .select("id")
    .eq("household_id", householdId)
    .eq("code", "pickup")
    .maybeSingle();
  if (definitionError) throw new Error(definitionError.message);
  if (!definition) {
    return { type: "needs_clarification", field: "お迎え予定", question: "その日のお迎え予定が見つかりません。予定を確認してください。" };
  }

  const { data: tasks, error: taskError } = await client
    .from("task_instances")
    .select("id,title,due_at,scheduled_date,revision,planned_assignee_id,status")
    .eq("household_id", householdId)
    .eq("task_definition_id", definition.id)
    .eq("scheduled_date", scheduledDate)
    .in("status", ["todo", "in_progress"])
    .is("test_context_id", null)
    .limit(2);
  if (taskError) throw new Error(taskError.message);
  if (!tasks || tasks.length !== 1) {
    return {
      type: "needs_clarification",
      field: "お迎え予定",
      question: tasks && tasks.length > 1
        ? "同じ日のお迎え予定が複数あります。対象を確認してください。"
        : "その日のお迎え予定が見つかりません。日付を確認してください。",
    };
  }

  const task = tasks[0];
  if (task.planned_assignee_id === recipientUserId) {
    return { type: "needs_clarification", field: "お迎え担当", question: "その日はすでにお願い先の担当です。現在の予定を確認してください。" };
  }
  if (task.planned_assignee_id !== actorId) {
    return { type: "needs_clarification", field: "お迎え担当", question: "その日は自分の担当ではありません。現在の担当を確認してください。" };
  }

  return {
    type: "assignment_change_request",
    taskId: String(task.id),
    taskRevision: Number(task.revision ?? 1),
    recipientUserId,
    scope: /今週(?:だけ)?/u.test(candidate.sourceText) ? "this_week" : "once",
    scheduledDate: String(task.scheduled_date),
    dueAt: typeof task.due_at === "string" ? task.due_at : null,
    currentAssigneeId: typeof task.planned_assignee_id === "string" ? task.planned_assignee_id : null,
  };
}
