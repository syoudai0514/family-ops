// verify_jwt=true. Explicit correction path for accidental whole-task completion.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const taskId = body["task_id"];
  const expectedRevision = body["expected_revision"];
  if (typeof taskId !== "string" || taskId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "task_id is required", 400);
  }
  if (typeof expectedRevision !== "number" || !Number.isSafeInteger(expectedRevision) || expectedRevision < 1) {
    throw new FamilyOpsError("INVALID_INPUT", "expected_revision is required", 400);
  }

  const serviceClient = createServiceRoleClient();
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
}));
