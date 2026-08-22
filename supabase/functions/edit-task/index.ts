// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #1 "edit-task". Restricted
// server-side to origin='manual' tasks and status in (todo, in_progress).
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const taskId = body["task_id"];
  if (typeof taskId !== "string" || taskId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "task_id is required", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ ok: true }>(
    serviceClient,
    "server_tx_edit_task_with_calendar",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_task_id: taskId,
      p_title: typeof body["title"] === "string" ? body["title"] : null,
      p_scheduled_date: typeof body["scheduled_date"] === "string" ? body["scheduled_date"] : null,
      p_due_local_time: typeof body["due_local_time"] === "string" ? body["due_local_time"] : null,
      p_calendar_end_local_time: typeof body["calendar_end_local_time"] === "string" ? body["calendar_end_local_time"] : null,
      p_category: typeof body["category"] === "string" ? body["category"] : null,
      p_planned_assignee_user_id: typeof body["planned_assignee_user_id"] === "string" ? body["planned_assignee_user_id"] : null,
      p_calendar_visibility: typeof body["calendar_visibility"] === "string" ? body["calendar_visibility"] : null,
    },
  );

  return jsonResponse(result);
}));
