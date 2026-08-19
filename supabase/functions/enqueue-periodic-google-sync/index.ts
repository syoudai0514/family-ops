// verify_jwt=false — cron worker (X-Family-Ops-Worker-Token).
// docs/design/v6/07_GOOGLE_CALENDAR.md; 10_WORK_PACKAGES.md WP7C "periodic
// 30m". Thin trigger: all coalescing/state-machine logic lives in the RPC
// (private.google_enqueue_sync via server_tx_enqueue_periodic_google_sync),
// this function only authenticates the caller and invokes it.
import { createServiceRoleClient, requireWorkerToken } from "../_shared/auth.ts";
import { withServiceHandler } from "../_shared/handler.ts";
import { callGoogleServerTx } from "../_shared/googleCalendar.ts";

Deno.serve(withServiceHandler(async (req: Request) => {
  requireWorkerToken(req);

  const serviceClient = createServiceRoleClient();
  const result = await callGoogleServerTx<{ enqueued_count: number }>(
    serviceClient,
    "server_tx_enqueue_periodic_google_sync",
    { p_stale_minutes: 30 },
  );

  return new Response(JSON.stringify(result), { status: 200, headers: { "Content-Type": "application/json" } });
}));
