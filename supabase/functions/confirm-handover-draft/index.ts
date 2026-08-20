// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #13 "AI rewrite
// confirmation" — confirm-handover-draft. Same shape as
// confirm-request-draft, delegating to the existing WP2
// server_tx_create_handover logic under a derived sub-operation-id (see
// docs/adr/0003-ai-draft-propose-endpoint.md).
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

const PERIODS = ["morning", "day", "evening", "other"];

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const rawInputId = body["raw_input_id"];
  const confirmedText = body["confirmed_text"];
  const period = body["period"];
  const occurredOn = body["occurred_on"];
  if (typeof rawInputId !== "string" || rawInputId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "raw_input_id is required", 400);
  }
  if (typeof confirmedText !== "string" || confirmedText.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "confirmed_text is required", 400);
  }
  if (typeof period !== "string" || !PERIODS.includes(period)) {
    throw new FamilyOpsError("INVALID_INPUT", `period must be one of ${PERIODS.join(", ")}`, 400);
  }
  if (typeof occurredOn !== "string" || occurredOn.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "occurred_on is required", 400);
  }
  const categories = body["categories"];
  if (categories !== undefined && (!Array.isArray(categories) || !categories.every((c) => typeof c === "string"))) {
    throw new FamilyOpsError("INVALID_INPUT", "categories must be an array of strings", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ handover_id: string }>(
    serviceClient,
    "server_tx_confirm_handover_draft",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_raw_input_id: rawInputId,
      p_confirmed_text: confirmedText,
      p_period: period,
      p_categories: categories ?? [],
      p_occurred_on: occurredOn,
    },
  );

  return jsonResponse(result);
}));
