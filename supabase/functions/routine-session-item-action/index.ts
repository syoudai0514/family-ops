// verify_jwt=true. Q64 exact individual reconciliation contract.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

const ALLOWED_ACTIONS = new Set([
  "complete", "partner_handled", "skip", "failed", "cancelled", "rescheduled", "unknown",
]);

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  const sessionId = body["session_id"];
  const taskInstanceId = body["task_instance_id"];
  const action = body["action"];
  if (typeof sessionId !== "string" || !sessionId || typeof taskInstanceId !== "string" || !taskInstanceId) {
    throw new FamilyOpsError("INVALID_INPUT", "session_id and task_instance_id are required", 400);
  }
  if (typeof action !== "string" || !ALLOWED_ACTIONS.has(action)) {
    throw new FamilyOpsError("INVALID_INPUT", "unsupported reconciliation action", 400);
  }
  const rescheduledTo = body["rescheduled_to"];
  if (action === "rescheduled" && (typeof rescheduledTo !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(rescheduledTo))) {
    throw new FamilyOpsError("INVALID_INPUT", "rescheduled_to is required for rescheduled", 400);
  }
  const reconciliationOperationId = typeof body["reconciliation_operation_id"] === "string"
    ? body["reconciliation_operation_id"] : null;

  return jsonResponse(await callServerTx(createServiceRoleClient(), "server_tx_routine_session_item_action_v3", {
    p_actor_id: actorId,
    p_operation_id: operationId,
    p_session_id: sessionId,
    p_task_instance_id: taskInstanceId,
    p_action: action,
    p_source: "pwa",
    p_rescheduled_to: action === "rescheduled" ? rescheduledTo : null,
    p_reconciliation_operation_id: reconciliationOperationId,
  }));
}));
