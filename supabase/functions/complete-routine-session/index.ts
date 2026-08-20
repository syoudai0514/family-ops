// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md #8 top-level "全部完了" /
// confirmed "今回は不要" (`disposition`: 'complete_all' | 'skip_incomplete').
// `source` is always 'pwa' here — the LINE-postback-shaped call into the
// same public.server_tx_complete_routine_session RPC is documented for a
// future process-line-inbox postback branch (out of this WP's edit scope;
// see the final report / docs/adr entry), exercised directly at the SQL
// layer in tests/sql for now (p_source='line').
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const sessionId = body["session_id"];
  if (typeof sessionId !== "string" || sessionId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "session_id is required", 400);
  }
  const disposition = body["disposition"];
  if (disposition !== "complete_all" && disposition !== "skip_incomplete") {
    throw new FamilyOpsError("INVALID_INPUT", "disposition must be complete_all or skip_incomplete", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx(
    serviceClient,
    "server_tx_complete_routine_session",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_session_id: sessionId,
      p_disposition: disposition,
      p_source: "pwa",
    },
  );

  return jsonResponse(result);
}));
