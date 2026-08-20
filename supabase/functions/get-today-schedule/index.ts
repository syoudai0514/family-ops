// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// Sol re-review #3 fix (P1-2, docs/adr/0011): Today Priority 1's "今/次の予定"
// (docs/design/v6/02_UX_AND_SCREENS.md #3) -- today's Google Calendar
// occurrences plus assigned/due task_instances, each already annotated
// with has_conflict by server_tx_get_today_schedule (20260819000102) using
// the exact same busy-attribution predicate the LINE digest's conflict
// count uses (private.fn_calendar_conflict_exists). The frontend performs
// zero calendar-domain filtering/overlap computation of its own -- it only
// renders what this RPC returns.
//
// Read, not a mutation -- no operation_id, same as get-routine-session /
// list-pending-actions.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx } from "../_shared/rpc.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx(
    serviceClient,
    "server_tx_get_today_schedule",
    { p_actor_id: actorId },
  );

  return jsonResponse(result);
}));
