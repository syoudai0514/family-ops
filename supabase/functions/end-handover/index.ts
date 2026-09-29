// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// Ends (clears) a handover for the whole household: status -> expired, the row
// stays in history. Any adult may do it (owner decision 2026-09-30, §8.2).
// Live 2026-09-30: a 'day' handover from 08-24 was still "未読" five weeks on,
// and nothing could end it.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const handoverId = body["handover_id"];
  if (typeof handoverId !== "string" || handoverId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "handover_id is required", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ ok: true; handover_id: string; status: string }>(
    serviceClient,
    "server_tx_end_handover",
    { p_actor_id: actorId, p_operation_id: operationId, p_handover_id: handoverId },
  );

  return jsonResponse(result);
}));
