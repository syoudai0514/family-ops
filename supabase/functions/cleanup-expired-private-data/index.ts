// verify_jwt=false — cron worker (docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md
// #14 "Cleanup": daily 03:30, fixed retention per table — see
// server_tx_cleanup_expired_private_data's migration header comment
// (20260819000090_recurring_holiday_cleanup_workers.sql) for the exact
// rule-by-rule breakdown and the one documented interpretation decision).
import { createServiceRoleClient, requireWorkerToken } from "../_shared/auth.ts";
import { withServiceHandler, jsonResponse } from "../_shared/handler.ts";

Deno.serve(withServiceHandler(async (req: Request) => {
  requireWorkerToken(req); // throws EDGE_WORKER_UNAUTHORIZED before any DB access

  const serviceClient = createServiceRoleClient();
  const { data, error } = await serviceClient.rpc("server_tx_cleanup_expired_private_data", {});
  if (error) {
    console.error("cleanup-expired-private-data: cleanup RPC failed", error.message);
    return new Response(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "internal error" } }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  return jsonResponse(data);
}));
