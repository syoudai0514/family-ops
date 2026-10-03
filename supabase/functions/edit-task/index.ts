// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #1 "edit-task". Restricted
// Schedule sharing also uses this authenticated adapter and its scoped RPC.
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
  if (body["sharing_action"] !== undefined) {
    const action = body["sharing_action"];
    if (typeof action !== "string" || !["register_attachment", "delete_attachment", "add_comment"].includes(action)) {
      throw new FamilyOpsError("INVALID_INPUT", "Invalid schedule sharing action", 400);
    }
    const result = await callServerTx<{ object_path?: string }>(serviceClient, "server_tx_mutate_schedule_sharing", {
      p_actor_id: actorId, p_operation_id: operationId, p_task_id: taskId,
      p_action: action, p_payload: body,
    });
    if (action === "delete_attachment" && result.object_path) {
      const { error } = await serviceClient.storage.from("schedule-attachments").remove([result.object_path]);
      if (error) throw new FamilyOpsError("INTERNAL_ERROR", "添付の削除を再試行してください。", 500);
    }
    return jsonResponse(result);
  }
  if (body["scheduler_details"] !== undefined) {
    const result = await callServerTx<{ task_id: string }>(serviceClient, "server_tx_save_scheduled_task", {
      p_actor_id: actorId, p_operation_id: operationId, p_task_id: taskId,
      p_expected_revision: body["expected_revision"] ?? null, p_payload: body,
    });
    return jsonResponse(result);
  }
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
