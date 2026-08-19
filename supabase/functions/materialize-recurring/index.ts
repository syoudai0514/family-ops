// verify_jwt=false — cron worker (docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md
// #13 "Recurrence worker": daily 00:10 Asia/Tokyo, today..+14d, all active
// rules). Drives private.materialize_recurrence_rule (WP1/WP3) across every
// currently-active recurrence_rules row via server_tx_materialize_recurring_batch,
// which is itself idempotent per Asia/Tokyo day via private.worker_run_receipts.
import { createServiceRoleClient, requireWorkerToken } from "../_shared/auth.ts";
import { withServiceHandler, jsonResponse } from "../_shared/handler.ts";

function todayAsiaTokyo(): string {
  // en-CA gives YYYY-MM-DD directly, matching Postgres `date` input format.
  return new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Tokyo" });
}

Deno.serve(withServiceHandler(async (req: Request) => {
  requireWorkerToken(req); // throws EDGE_WORKER_UNAUTHORIZED before any DB access

  const serviceClient = createServiceRoleClient();
  const today = todayAsiaTokyo();

  const { data, error } = await serviceClient.rpc("server_tx_materialize_recurring_batch", {
    p_today: today,
  });
  if (error) {
    console.error("materialize-recurring: batch RPC failed", error.message);
    return new Response(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "internal error" } }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  return jsonResponse({ today, ...(data as object) });
}));
