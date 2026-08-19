// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/06_LINE_INTEGRATION.md #2: sets the caller's own
// private.line_user_links row to status='unlinked'. Idempotent — unlinking
// an already-unlinked (or never-linked) account is a success no-op
// (was_linked=false) rather than an error, since the caller's desired end
// state (not linked) already holds either way.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";

interface UnlinkLineAccountResult {
  was_linked: boolean;
  unlinked_at: string | null;
}

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<UnlinkLineAccountResult>(
    serviceClient,
    "server_tx_unlink_line_account",
    { p_actor_id: actorId, p_operation_id: operationId },
  );

  return jsonResponse(result);
}));
