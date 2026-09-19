// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// Reuses one user-mutation Edge Function slot for both completion and explicit
// completion correction; the database keeps separate canonical RPCs.
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

  if (body["action"] === "reopen") {
    const expectedRevision = body["expected_revision"];
    if (typeof expectedRevision !== "number" || !Number.isSafeInteger(expectedRevision) || expectedRevision < 1) {
      throw new FamilyOpsError("INVALID_INPUT", "expected_revision is required", 400);
    }
    const result = await callServerTx<{ ok: true; task_id: string; status: string; revision: number }>(
      serviceClient,
      "server_tx_reopen_task",
      {
        p_actor_id: actorId,
        p_operation_id: operationId,
        p_task_id: taskId,
        p_expected_revision: expectedRevision,
        p_source: "pwa",
      },
    );
    return jsonResponse(result);
  }

  const completionActor = body["completion_actor"];
  if (completionActor !== "self" && completionActor !== "partner") {
    throw new FamilyOpsError("INVALID_INPUT", "completion_actor must be 'self' or 'partner'", 400);
  }

  const result = await callServerTx<{ ok: true }>(
    serviceClient,
    "server_tx_complete_task",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_task_id: taskId,
      p_completion_actor: completionActor,
      p_complete_remaining_subtasks: body["complete_remaining_subtasks"] === true,
    },
  );

  return jsonResponse(result);
}));
