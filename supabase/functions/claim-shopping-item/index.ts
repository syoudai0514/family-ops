// verify_jwt=true. Canonical anyone-claim/release/takeover endpoint.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  const shoppingItemId = body["shopping_item_id"];
  const action = body["action"];
  const expectedRevision = body["expected_revision"];
  if (typeof shoppingItemId !== "string" || shoppingItemId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "shopping_item_id is required", 400);
  }
  if (typeof action !== "string" || !["claim", "release", "takeover"].includes(action)) {
    throw new FamilyOpsError("INVALID_INPUT", "action is invalid", 400);
  }
  if (typeof expectedRevision !== "number" || !Number.isSafeInteger(expectedRevision) || expectedRevision < 1) {
    throw new FamilyOpsError("INVALID_INPUT", "expected_revision is required", 400);
  }
  const result = await callServerTx(
    createServiceRoleClient(),
    "server_tx_shopping_claim_v2",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_shopping_item_id: shoppingItemId,
      p_action: action,
      p_expected_revision: expectedRevision,
    },
  );
  return jsonResponse(result);
}));

