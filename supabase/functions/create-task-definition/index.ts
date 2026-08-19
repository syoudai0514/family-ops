// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #2 "create-task-definition".
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

interface SubtaskInput {
  title: string;
  required?: boolean;
  sort_order?: number;
}

function isSubtaskArray(value: unknown): value is SubtaskInput[] {
  if (!Array.isArray(value)) return false;
  return value.every((s) =>
    typeof s === "object" && s !== null && typeof (s as Record<string, unknown>).title === "string"
  );
}

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const code = body["code"];
  const title = body["title"];
  const category = body["category"];
  const routinePhase = body["routine_phase"];
  const completionMode = body["completion_mode"];
  if (typeof code !== "string" || code.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "code is required", 400);
  }
  if (typeof title !== "string" || title.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "title is required", 400);
  }
  if (typeof category !== "string" || category.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "category is required", 400);
  }
  if (typeof routinePhase !== "string" || !["morning", "evening", "anytime"].includes(routinePhase)) {
    throw new FamilyOpsError("INVALID_INPUT", "routine_phase must be morning/evening/anytime", 400);
  }
  if (completionMode !== "whole" && completionMode !== "subtasks") {
    throw new FamilyOpsError("INVALID_INPUT", "completion_mode must be 'whole' or 'subtasks'", 400);
  }
  const subtasks = body["subtasks"];
  if (subtasks !== undefined && subtasks !== null && !isSubtaskArray(subtasks)) {
    throw new FamilyOpsError("INVALID_INPUT", "subtasks must be an array of {title, required?, sort_order?}", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ task_definition_id: string }>(
    serviceClient,
    "server_tx_create_task_definition",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_code: code,
      p_title: title,
      p_category: category,
      p_routine_phase: routinePhase,
      p_completion_mode: completionMode,
      p_sort_order: typeof body["sort_order"] === "number" ? body["sort_order"] : null,
      p_subtasks: subtasks ?? null,
    },
  );

  return jsonResponse(result);
}));
