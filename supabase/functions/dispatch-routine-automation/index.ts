// verify_jwt=false — cron worker class (see supabase/config.toml +
// EDGE_FUNCTION_AUTH_MATRIX.md "Worker"). docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md
// #7 "dispatch-routine-automation"; 17_ROUTINE_LINE_AUTOMATION.md #13
// "Scheduler worker ... every 1 minute".
//
// All business logic (schedule matching, session get-or-create, bundling,
// idempotent claim, notification_outbox insert) lives in
// public.server_tx_dispatch_routine_automation (20260819000082) — this
// handler only authenticates the worker and forwards the current instant,
// same split as send-notifications/process-line-inbox.
import { createServiceRoleClient, requireWorkerToken } from "../_shared/auth.ts";
import { withServiceHandler, jsonResponse } from "../_shared/handler.ts";

Deno.serve(withServiceHandler(async (req: Request) => {
  requireWorkerToken(req); // throws EDGE_WORKER_UNAUTHORIZED before any DB access

  const serviceClient = createServiceRoleClient();

  const { data, error } = await serviceClient.rpc("server_tx_dispatch_routine_automation", {
    p_now_utc: new Date().toISOString(),
  });

  if (error) {
    console.error("dispatch-routine-automation: RPC failed", error.message);
    return new Response(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "internal error" } }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  return jsonResponse(data);
}));
