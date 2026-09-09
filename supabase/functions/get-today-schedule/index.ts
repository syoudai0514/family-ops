// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// Compatibility read for callers that still need the established detailed
// occurrence/assignment schedule shape. PWA Today itself now consumes the
// canonical DailyBrief; this Edge remains only for callers of the historical
// schedule contract and therefore delegates to server_tx_get_today_schedule.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx } from "../_shared/rpc.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx(
    serviceClient,
    "server_tx_get_today_schedule",
    { p_actor_id: actorId },
  );

  return jsonResponse(result);
}));
