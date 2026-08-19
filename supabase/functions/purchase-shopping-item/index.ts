// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #6 "purchase-shopping-item".
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

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ ok: true }>(
    serviceClient,
    "server_tx_purchase_shopping_item",
    { p_actor_id: actorId, p_operation_id: operationId, p_shopping_item_id: shoppingItemId },
  );

  return jsonResponse(result);
}));
