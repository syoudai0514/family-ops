// verify_jwt=true — authenticated household member creates an actionable
// next-day preparation task and the handover notification in one DB transaction.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const title = body["title"];
  const scheduledDate = body["scheduled_date"];
  const plannedAssigneeUserId = body["planned_assignee_user_id"];

  if (typeof title !== "string" || title.trim().length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "title is required", 400);
  }
  if (typeof scheduledDate !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(scheduledDate)) {
    throw new FamilyOpsError("INVALID_INPUT", "scheduled_date must be YYYY-MM-DD", 400);
  }
  if (
    plannedAssigneeUserId !== undefined &&
    plannedAssigneeUserId !== null &&
    (typeof plannedAssigneeUserId !== "string" || plannedAssigneeUserId.length === 0)
  ) {
    throw new FamilyOpsError("INVALID_INPUT", "planned_assignee_user_id must be a user id", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ task_id: string; handover_id: string }>(
    serviceClient,
    "server_tx_create_preparation_handoff",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_title: title.trim(),
      p_scheduled_date: scheduledDate,
      p_planned_assignee_id:
        typeof plannedAssigneeUserId === "string" ? plannedAssigneeUserId : null,
    },
  );

  return jsonResponse(result);
}));
