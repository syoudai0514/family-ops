// verify_jwt=true. docs/design/v6/07_GOOGLE_CALENDAR.md #14 "app
// stale/manual trigger" — called when the PWA opens the calendar view (or
// ~10m before the Sunday weekly digest) so a stale cache gets a coalesced
// sync enqueued without the caller waiting on it to finish.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callGoogleServerTx } from "../_shared/googleCalendar.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const serviceClient = createServiceRoleClient();

  const result = await callGoogleServerTx(serviceClient, "server_tx_ensure_calendar_fresh", {
    p_actor_id: actorId,
    p_stale_minutes: 5,
  });

  return jsonResponse(result);
}));
