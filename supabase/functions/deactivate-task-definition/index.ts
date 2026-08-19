// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #2 "deactivate-task-definition".
// Soft-deactivate only (is_active=false) — hard delete is prohibited.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const taskDefinitionId = body["task_definition_id"];
  if (typeof taskDefinitionId !== "string" || taskDefinitionId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "task_definition_id is required", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ ok: true }>(
    serviceClient,
    "server_tx_deactivate_task_definition",
    { p_actor_id: actorId, p_operation_id: operationId, p_task_definition_id: taskDefinitionId },
  );

  return jsonResponse(result);
}));
