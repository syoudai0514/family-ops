// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md #9 "PWA check-in screen"; the
// PWA deep link {APP_BASE_URL}/checkin/{session_id} (#8) resolves the
// session's current state through this read. Any household member may read
// (SL-16 "same canonical task/session state visible" from either channel);
// mutation is restricted to the session's own assignee inside the RPC.
//
// This is a read, not a mutation — no operation_id (nothing to make
// idempotent) and no callServerTx wrapping needed beyond the standard
// server_tx error-code translation, so it's called directly.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);

  const sessionId = body["session_id"];
  if (typeof sessionId !== "string" || sessionId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "session_id is required", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx(
    serviceClient,
    "server_tx_get_routine_session",
    { p_actor_id: actorId, p_session_id: sessionId },
  );

  return jsonResponse(result);
}));
