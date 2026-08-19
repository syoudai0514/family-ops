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

  const householdName = body["household_name"];
  const displayName = body["display_name"];
  if (typeof householdName !== "string" || typeof displayName !== "string") {
    throw new FamilyOpsError("INVALID_INPUT", "household_name and display_name are required", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ household_id: string }>(
    serviceClient,
    "server_tx_create_household",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_household_name: householdName,
      p_display_name: displayName,
    },
  );

  return jsonResponse({ household_id: result.household_id });
}));
