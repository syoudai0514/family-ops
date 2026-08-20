// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #3 "reassign-task-once".
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const taskId = body["task_id"];
  const newAssigneeUserId = body["new_assignee_user_id"];
  if (typeof taskId !== "string" || taskId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "task_id is required", 400);
  }
  if (typeof newAssigneeUserId !== "string" || newAssigneeUserId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "new_assignee_user_id is required", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ ok: true; task_id: string; new_assignee_user_id: string }>(
    serviceClient,
    "server_tx_reassign_task_once",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_task_id: taskId,
      p_new_assignee_user_id: newAssigneeUserId,
    },
  );

  return jsonResponse(result);
}));
