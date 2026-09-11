// verify_jwt=true. Human-confirmed Concierge duplicate resolution only.
// This endpoint never creates a replacement row: update is CAS against the
// matched canonical entity, and conflicts are returned to the caller.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import { jsonResponse, withUserMutationHandler } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const entityKind = body["entity_kind"];
  const entityId = body["entity_id"];
  const expectedRevision = body["expected_revision"];
  const title = body["title"];
  if ((entityKind !== "task" && entityKind !== "shopping") ||
      typeof entityId !== "string" || !entityId ||
      typeof expectedRevision !== "number" || !Number.isInteger(expectedRevision) || expectedRevision < 1 ||
      typeof title !== "string" || !title.trim()) {
    throw new FamilyOpsError("INVALID_INPUT", "matched entity, revision and title are required", 400);
  }

  const scheduledDate = typeof body["scheduled_date"] === "string" ? body["scheduled_date"] : null;
  const dueLocalTime = typeof body["due_local_time"] === "string" ? body["due_local_time"] : null;
  const plannedAssigneeUserId = typeof body["planned_assignee_user_id"] === "string"
    ? body["planned_assignee_user_id"]
    : null;

  const client = createServiceRoleClient();
  const result = await callServerTx<Record<string, unknown>>(
    client,
    "server_tx_commit_concierge_duplicate_update",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_entity_kind: entityKind,
      p_entity_id: entityId,
      p_expected_revision: expectedRevision,
      p_title: title.trim(),
      p_scheduled_date: scheduledDate,
      p_due_local_time: dueLocalTime,
      p_planned_assignee_user_id: plannedAssigneeUserId,
    },
  );
  return jsonResponse(result);
}));
