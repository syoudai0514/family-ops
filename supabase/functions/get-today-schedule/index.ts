// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// Compatibility read for callers that still need the former detailed
// occurrence/assignment schedule shape. PWA Today no longer calls this Edge
// function; its semantic source is get_my_daily_brief. The historical
// server_tx_get_today_schedule name is intentionally reserved for the LINE
// 「今日」 compatibility adapter over canonical DailyBrief (Lane D CF-02).
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx } from "../_shared/rpc.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx(
    serviceClient,
    "server_read_today_schedule_legacy_v1",
    { p_actor_id: actorId },
  );

  return jsonResponse(result);
}));
