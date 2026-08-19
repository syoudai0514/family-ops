// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #9 "change recurrence".
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

const ASSIGNEE_STRATEGIES = ["fixed", "dropoff_assignee", "pickup_assignee", "nonpickup_adult", "unassigned"];

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const taskDefinitionId = body["task_definition_id"];
  const weekday = body["weekday"];
  const assigneeStrategy = body["assignee_strategy"];
  const effectiveFrom = body["effective_from"];

  if (typeof taskDefinitionId !== "string" || taskDefinitionId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "task_definition_id is required", 400);
  }
  if (typeof weekday !== "number" || !Number.isInteger(weekday) || weekday < 1 || weekday > 7) {
    throw new FamilyOpsError("INVALID_INPUT", "weekday must be an integer 1-7", 400);
  }
  if (typeof assigneeStrategy !== "string" || !ASSIGNEE_STRATEGIES.includes(assigneeStrategy)) {
    throw new FamilyOpsError("INVALID_INPUT", "assignee_strategy is invalid", 400);
  }
  if (typeof effectiveFrom !== "string" || effectiveFrom.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "effective_from is required", 400);
  }

  const slotKey = body["slot_key"];
  if (slotKey !== undefined && slotKey !== null && typeof slotKey !== "string") {
    throw new FamilyOpsError("INVALID_INPUT", "slot_key must be a string", 400);
  }

  const plannedAssigneeUserId = body["planned_assignee_user_id"];
  if (plannedAssigneeUserId !== undefined && plannedAssigneeUserId !== null && typeof plannedAssigneeUserId !== "string") {
    throw new FamilyOpsError("INVALID_INPUT", "planned_assignee_user_id must be a string", 400);
  }

  const scheduledLocalTime = body["scheduled_local_time"];
  if (scheduledLocalTime !== undefined && scheduledLocalTime !== null && typeof scheduledLocalTime !== "string") {
    throw new FamilyOpsError("INVALID_INPUT", "scheduled_local_time must be a string", 400);
  }

  const conflictWindowMinutes = body["conflict_window_minutes"];
  if (
    conflictWindowMinutes !== undefined && conflictWindowMinutes !== null &&
    (typeof conflictWindowMinutes !== "number" || !Number.isInteger(conflictWindowMinutes))
  ) {
    throw new FamilyOpsError("INVALID_INPUT", "conflict_window_minutes must be an integer", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ rule_id: string }>(
    serviceClient,
    "server_tx_change_recurrence",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_task_definition_id: taskDefinitionId,
      p_weekday: weekday,
      p_slot_key: typeof slotKey === "string" ? slotKey : null,
      p_assignee_strategy: assigneeStrategy,
      p_planned_assignee_user_id: typeof plannedAssigneeUserId === "string" ? plannedAssigneeUserId : null,
      p_scheduled_local_time: typeof scheduledLocalTime === "string" ? scheduledLocalTime : null,
      p_conflict_window_minutes: typeof conflictWindowMinutes === "number" ? conflictWindowMinutes : null,
      p_effective_from: effectiveFrom,
    },
  );

  return jsonResponse(result);
}));
