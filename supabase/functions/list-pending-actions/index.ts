// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// Sol re-review #3 fix (P1-1, docs/adr/0011): Today Priority 2's "LINEから
// 作ったpending action" (docs/design/v6/02_UX_AND_SCREENS.md #3) -- reads
// the current actor's own non-terminal draft/confirmed/queued/executing
// private.pending_actions rows via server_tx_list_pending_actions
// (20260819000102). Never another household member's -- a draft is the
// sender's own private natural-language input until confirmed.
//
// This is a read, not a mutation -- no operation_id needed, same as
// get-routine-session.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx } from "../_shared/rpc.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx(
    serviceClient,
    "server_tx_list_pending_actions",
    { p_actor_id: actorId },
  );

  return jsonResponse(result);
}));
