// verify_jwt=true. "この日は送迎なし": cancels the day's dropoff / pickup, Codmon and weekday-only
// morning tasks (history kept, never made again) and makes what followed the dropoff / pickup
// person 誰でもOK. One service-role-only transactional RPC.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  const date = body["date"];
  if (typeof date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(new Date(`${date}T00:00:00Z`).getTime())) {
    throw new FamilyOpsError("INVALID_INPUT", "date (yyyy-mm-dd) is required", 400);
  }
  return jsonResponse(
    await callServerTx<{ ok: true; cancelled: number; made_anyone: number }>(
      createServiceRoleClient(),
      "server_tx_clear_day_transport_v1",
      { p_actor_id: actorId, p_operation_id: operationId, p_date: date },
    ),
  );
}));
