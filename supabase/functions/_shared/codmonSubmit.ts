import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

/**
 * True when the task is the day's コドモン送信 (definition code codmon_submit).
 * That task is completed one way only: "sent" ends the job and closes any input
 * still open (owner decision 2026-09-30). Screens that do not carry the day's
 * Codmon readiness (the week/month day sheet, an overdue day) send a plain
 * completion, which the codmon_submit guard refuses while an input is open.
 * Any lookup failure answers false so the ordinary completion path decides.
 */
export async function isCodmonSubmitTask(client: SupabaseClient, taskId: string): Promise<boolean> {
  const { data: task, error: taskError } = await client
    .from("task_instances").select("task_definition_id").eq("id", taskId).maybeSingle();
  const definitionId = (task as { task_definition_id?: string | null } | null)?.task_definition_id;
  if (taskError || !definitionId) return false;
  const { data: definition, error: definitionError } = await client
    .from("task_definitions").select("code").eq("id", definitionId).maybeSingle();
  return !definitionError && (definition as { code?: string } | null)?.code === "codmon_submit";
}
