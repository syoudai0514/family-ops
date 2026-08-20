// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #0A.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const rawInviteToken = body["raw_invite_token"];
  const displayName = body["display_name"];
  if (typeof rawInviteToken !== "string" || rawInviteToken.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "raw_invite_token is required", 400);
  }
  if (typeof displayName !== "string" || displayName.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "display_name is required", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ household_id: string }>(
    serviceClient,
    "server_tx_join_household",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_raw_invite_token: rawInviteToken,
      p_display_name: displayName,
    },
  );

  return jsonResponse({ household_id: result.household_id });
}));
