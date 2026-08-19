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
import { createServiceRoleClient, requireWorkerToken } from "../_shared/auth.ts";
import { withServiceHandler, jsonResponse } from "../_shared/handler.ts";

Deno.serve(withServiceHandler(async (req: Request) => {
  requireWorkerToken(req); // throws EDGE_WORKER_UNAUTHORIZED before any DB access

  const serviceClient = createServiceRoleClient();
  const { count, error } = await serviceClient
    .from("notification_outbox")
    .select("*", { count: "exact", head: true })
    .eq("status", "queued");

  if (error) {
    console.error("send-notifications: failed to count queued outbox rows", error.message);
    return jsonResponse({ queued: null }, 200);
  }

  return jsonResponse({ queued: count ?? 0 });
}));
