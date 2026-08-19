// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #6 "add-shopping-item".
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

const PURCHASE_METHODS = ["store", "online", "either", "undecided"];

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const title = body["title"];
  const purchaseMethod = body["purchase_method"];
  if (typeof title !== "string" || title.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "title is required", 400);
  }
  if (typeof purchaseMethod !== "string" || !PURCHASE_METHODS.includes(purchaseMethod)) {
    throw new FamilyOpsError("INVALID_INPUT", `purchase_method must be one of ${PURCHASE_METHODS.join(", ")}`, 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ shopping_item_id: string }>(
    serviceClient,
    "server_tx_add_shopping_item",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_title: title,
      p_purchase_method: purchaseMethod,
      p_assignee_user_id: typeof body["assignee_user_id"] === "string" ? body["assignee_user_id"] : null,
      p_url: typeof body["url"] === "string" ? body["url"] : null,
      p_due_at: typeof body["due_at"] === "string" ? body["due_at"] : null,
    },
  );

  return jsonResponse(result);
}));
