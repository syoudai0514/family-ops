// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md request section "accept-request".
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const requestId = body["request_id"];
  if (typeof requestId !== "string" || requestId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "request_id is required", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ task_id: string }>(
    serviceClient,
    "server_tx_accept_request",
    { p_actor_id: actorId, p_operation_id: operationId, p_request_id: requestId },
  );

  return jsonResponse(result);
}));
