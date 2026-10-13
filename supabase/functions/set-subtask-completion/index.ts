// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #1 "set-subtask-completion".
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const subtaskInstanceId = body["subtask_instance_id"];
  const completed = body["completed"];
  const completionActor = body["completion_actor"];
  const expectedRevision = body["expected_revision"];
  if (typeof subtaskInstanceId !== "string" || subtaskInstanceId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "subtask_instance_id is required", 400);
  }
  if (typeof completed !== "boolean") {
    throw new FamilyOpsError("INVALID_INPUT", "completed must be a boolean", 400);
  }
  if (completionActor !== "self" && completionActor !== "partner" && completionActor !== "unknown") {
    throw new FamilyOpsError("INVALID_INPUT", "completion_actor must be 'self', 'partner', or 'unknown'", 400);
  }
  if (expectedRevision !== undefined &&
    (typeof expectedRevision !== "number" || !Number.isSafeInteger(expectedRevision) || expectedRevision < 1)) {
    throw new FamilyOpsError("INVALID_INPUT", "expected_revision must be a positive integer", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ ok: true }>(
    serviceClient,
    "server_tx_set_subtask_completion",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_subtask_instance_id: subtaskInstanceId,
      p_completed: completed,
      p_completion_actor: completionActor,
      ...(expectedRevision === undefined ? {} : { p_expected_revision: expectedRevision }),
    },
  );

  return jsonResponse(result);
}));
