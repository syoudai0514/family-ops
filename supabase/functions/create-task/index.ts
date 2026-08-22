// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #1 "create-task".
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

interface SubtaskInput {
  title: string;
  required?: boolean;
  sort_order?: number;
}

function isSubtaskArray(value: unknown): value is SubtaskInput[] {
  if (!Array.isArray(value)) return false;
  return value.every((s) =>
    typeof s === "object" && s !== null && typeof (s as Record<string, unknown>).title === "string"
  );
}

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const title = body["title"];
  const scheduledDate = body["scheduled_date"];
  const completionMode = body["completion_mode"];
  if (typeof title !== "string" || title.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "title is required", 400);
  }
  if (typeof scheduledDate !== "string" || scheduledDate.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "scheduled_date is required", 400);
  }
  if (completionMode !== "whole" && completionMode !== "subtasks") {
    throw new FamilyOpsError("INVALID_INPUT", "completion_mode must be 'whole' or 'subtasks'", 400);
  }
  const subtasks = body["subtasks"];
  if (subtasks !== undefined && subtasks !== null && !isSubtaskArray(subtasks)) {
    throw new FamilyOpsError("INVALID_INPUT", "subtasks must be an array of {title, required?, sort_order?}", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ task_id: string }>(
    serviceClient,
    "server_tx_create_task_with_calendar",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_title: title,
      p_category: typeof body["category"] === "string" ? body["category"] : null,
      p_scheduled_date: scheduledDate,
      p_due_local_time: typeof body["due_local_time"] === "string" ? body["due_local_time"] : null,
      p_calendar_end_local_time: typeof body["calendar_end_local_time"] === "string" ? body["calendar_end_local_time"] : null,
      p_calendar_visibility: typeof body["calendar_visibility"] === "string" ? body["calendar_visibility"] : "hidden",
      p_planned_assignee_user_id: typeof body["planned_assignee_user_id"] === "string" ? body["planned_assignee_user_id"] : null,
      p_completion_mode: completionMode,
      p_routine_phase: typeof body["routine_phase"] === "string" ? body["routine_phase"] : null,
      p_subtasks: subtasks ?? null,
    },
  );

  return jsonResponse(result);
}));
