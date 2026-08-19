// verify_jwt=false — cron worker class (see supabase/config.toml +
// EDGE_FUNCTION_AUTH_MATRIX.md). Handler order is safety-critical: the
// worker token MUST be checked before any service-role client is created or
// any DB row is touched (docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md #15;
// EDGE_FUNCTION_AUTH_MATRIX.md "Worker").
//
// The actual LINE-send loop (outbox claim, atomic quota permit via
// server_tx_reserve_line_quota, provider call, retry-key handling,
// delivery_unknown reconciliation) is WP6 scope
// (docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md #6 "send-notifications").
// This function exists in WP1 to prove out and test the worker-auth
// boundary end to end; it authenticates and reports how much outbox work is
// currently queued without sending anything.
//
// v6 review fix (P1-2): private.notification_outbox must never be reached
// via the Data API `.from()` client, even under service_role — go through
// public.server_tx_count_queued_notifications (see
// docs/design/v6/15_DDL_CONTRACT.md #8).
import { createServiceRoleClient, requireWorkerToken } from "../_shared/auth.ts";
import { withServiceHandler, jsonResponse } from "../_shared/handler.ts";

Deno.serve(withServiceHandler(async (req: Request) => {
  requireWorkerToken(req); // throws EDGE_WORKER_UNAUTHORIZED before any DB access

  const serviceClient = createServiceRoleClient();
  const { data: queued, error } = await serviceClient.rpc("server_tx_count_queued_notifications");

  if (error) {
    console.error("send-notifications: failed to count queued outbox rows", error.message);
    return new Response(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "internal error" } }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  return jsonResponse({ queued: queued ?? 0 });
}));
