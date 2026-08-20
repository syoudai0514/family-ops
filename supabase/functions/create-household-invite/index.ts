// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #0A.
//
// The raw invite token is returned exactly once, in this response, on first
// issuance. It is never persisted anywhere (only its SHA-256 hash is stored
// in private.household_invites) and a replay of the same operation_id raises
// INVITE_TOKEN_ALREADY_ISSUED rather than re-issuing it.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{
    invite_id: string;
    household_id: string;
    raw_token: string;
    expires_at: string;
  }>(
    serviceClient,
    "server_tx_create_household_invite",
    { p_actor_id: actorId, p_operation_id: operationId },
  );

  return jsonResponse({
    invite_id: result.invite_id,
    raw_token: result.raw_token,
    expires_at: result.expires_at,
  });
}));
