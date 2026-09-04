// verify_jwt=true. Post-accept change/cancel creates a new canonical Attempt.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  const requestId = body["request_id"];
  const attemptKind = body["attempt_kind"];
  const expectedRequestRevision = body["expected_request_revision"];
  const expectedTaskRevision = body["expected_task_revision"];
  if (typeof requestId !== "string" || requestId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "request_id is required", 400);
  }
  if (attemptKind !== "change" && attemptKind !== "cancel") {
    throw new FamilyOpsError("INVALID_INPUT", "attempt_kind is invalid", 400);
  }
  if (typeof expectedRequestRevision !== "number" || !Number.isSafeInteger(expectedRequestRevision)) {
    throw new FamilyOpsError("INVALID_INPUT", "expected_request_revision is required", 400);
  }
  if (typeof expectedTaskRevision !== "number" || !Number.isSafeInteger(expectedTaskRevision)) {
    throw new FamilyOpsError("INVALID_INPUT", "expected_task_revision is required", 400);
  }
  const taskPatch = body["task_patch"];
  if (attemptKind === "change" && (typeof taskPatch !== "object" || taskPatch === null || Array.isArray(taskPatch))) {
    throw new FamilyOpsError("INVALID_INPUT", "task_patch is required", 400);
  }
  const result = await callServerTx(
    createServiceRoleClient(),
    "server_tx_start_request_followup",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_request_id: requestId,
      p_attempt_kind: attemptKind,
      p_task_patch: attemptKind === "change" ? taskPatch : null,
      p_reason: typeof body["reason"] === "string" ? body["reason"] : null,
      p_reply_due_at: typeof body["reply_due_at"] === "string" ? body["reply_due_at"] : null,
      p_expected_request_revision: expectedRequestRevision,
      p_expected_task_revision: expectedTaskRevision,
    },
  );
  return jsonResponse(result);
}));

