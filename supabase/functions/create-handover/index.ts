// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #7 "create-handover". WP5
// Normal handovers remain immutable. When scheduled_date is supplied, this
// same endpoint creates an actionable morning-preparation task and its
// handover atomically so the pickup person can pass tomorrow's items to the
// morning person without a second form.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

const PERIODS = ["morning", "day", "evening", "other"];

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  const serviceClient = createServiceRoleClient();

  const scheduledDate = body["scheduled_date"];
  if (scheduledDate !== undefined && scheduledDate !== null) {
    const title = body["title"] ?? body["shared_text"];
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
  }

  const sharedText = body["shared_text"];
  const period = body["period"];
  const occurredOn = body["occurred_on"];
  if (typeof sharedText !== "string" || sharedText.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "shared_text is required", 400);
  }
  if (typeof period !== "string" || !PERIODS.includes(period)) {
    throw new FamilyOpsError("INVALID_INPUT", `period must be one of ${PERIODS.join(", ")}`, 400);
  }
  if (typeof occurredOn !== "string" || occurredOn.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "occurred_on is required", 400);
  }
  const categories = body["categories"];
  if (categories !== undefined && (!Array.isArray(categories) || !categories.every((c) => typeof c === "string"))) {
    throw new FamilyOpsError("INVALID_INPUT", "categories must be an array of strings", 400);
  }

  const result = await callServerTx<{ handover_id: string }>(
    serviceClient,
    "server_tx_create_handover",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_shared_text: sharedText,
      p_period: period,
      p_categories: categories ?? [],
      p_occurred_on: occurredOn,
    },
  );

  return jsonResponse(result);
}));
