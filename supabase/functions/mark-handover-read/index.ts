// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #7 "mark-handover-read".
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

  // action "end": clear the note for the whole household (any adult;
  // Requirements §8.2 / §29.2). Carried by this function rather than a new
  // one because the project is at its plan's Edge Function limit.
  if (body["action"] === "end") {
    const ended = await callServerTx<{ ok: true; handover_id: string; status: string }>(
      serviceClient,
      "server_tx_end_handover",
      { p_actor_id: actorId, p_operation_id: operationId, p_handover_id: handoverId },
    );
    return jsonResponse(ended);
  }

  const result = await callServerTx<{ ok: true }>(
    serviceClient,
    "server_tx_mark_handover_read",
    { p_actor_id: actorId, p_operation_id: operationId, p_handover_id: handoverId },
  );

  return jsonResponse(result);
}));
