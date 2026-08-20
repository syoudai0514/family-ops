// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// Sol re-review #3 fix (P1-1, docs/adr/0011): the PWA half of cancelling a
// LINE-created draft pending action -- mirrors confirm-pending-action but
// wraps server_tx_cancel_pending_action (20260819000041, unchanged).
// Performs no business mutation of its own; the underlying RPC only ever
// flips private.pending_actions.status, never touches a task/shopping/etc.
// row.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);

  const pendingActionId = body["pending_action_id"];
  if (typeof pendingActionId !== "string" || pendingActionId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "pending_action_id is required", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx(
    serviceClient,
    "server_tx_cancel_pending_action",
    { p_actor_id: actorId, p_pending_action_id: pendingActionId },
  );

  return jsonResponse(result);
}));
