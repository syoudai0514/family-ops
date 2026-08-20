// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// Sol re-review #3 fix (P1-1, docs/adr/0011): the PWA half of confirming a
// LINE-created draft pending action (docs/design/v6/06_LINE_INTEGRATION.md
// #9 "Confirmation postback itself never performs external side-effect
// inline; it marks confirmed then worker executes") -- process-line-inbox
// already calls this exact RPC for its own `confirm_pending` postback
// (supabase/functions/process-line-inbox/index.ts); this wraps the SAME
// server_tx_confirm_pending_action (20260819000041, unchanged) for the PWA
// caller instead, with the same (p_actor_id, p_pending_action_id) shape --
// no operation_id, matching that RPC's own signature (its idempotency is
// the status-check "already confirmed -> no-op replay" pattern the RPC
// itself already implements, not the mutation_receipts/operation_id
// pattern most other server_tx_* mutations use).
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
    "server_tx_confirm_pending_action",
    { p_actor_id: actorId, p_pending_action_id: pendingActionId },
  );

  return jsonResponse(result);
}));
