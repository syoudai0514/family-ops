// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #6 "assign-shopping-item"
// (assign/unassign in one endpoint: assignee_user_id null/absent = unassign).
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const shoppingItemId = body["shopping_item_id"];
  if (typeof shoppingItemId !== "string" || shoppingItemId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "shopping_item_id is required", 400);
  }
  const assigneeUserId = body["assignee_user_id"];
  const assignmentMode = body["assignment_mode"] ?? (assigneeUserId ? "person" : "unassigned");
  const expectedRevision = body["expected_revision"];
  if (assigneeUserId !== null && assigneeUserId !== undefined && typeof assigneeUserId !== "string") {
    throw new FamilyOpsError("INVALID_INPUT", "assignee_user_id must be a string or null", 400);
  }
  if (typeof assignmentMode !== "string" || !["person", "unassigned", "anyone"].includes(assignmentMode)) {
    throw new FamilyOpsError("INVALID_INPUT", "assignment_mode is invalid", 400);
  }
  if (typeof expectedRevision !== "number" || !Number.isSafeInteger(expectedRevision) || expectedRevision < 1) {
    throw new FamilyOpsError("INVALID_INPUT", "expected_revision is required", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ ok: true }>(
    serviceClient,
    "server_tx_set_shopping_assignment_v2",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_shopping_item_id: shoppingItemId,
      p_assignment_mode: assignmentMode,
      p_assignee_user_id: typeof assigneeUserId === "string" ? assigneeUserId : null,
      p_expected_revision: expectedRevision,
    },
  );

  return jsonResponse(result);
}));
