// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #9 "update-routine-schedule".
// No weekday input — see the RPC migration's comment for why (all 9 live
// schedule kinds are weekday-independent per the current schema).
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

const SCHEDULE_KINDS = [
  "daily_assignment",
  "dropoff_checklist", "dropoff_checkin",
  "pickup_checklist", "pickup_checkin",
  "nonpickup_evening_checklist", "nonpickup_evening_checkin",
  "nonworkday_morning_digest", "nonworkday_checkin",
];

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const scheduleKind = body["schedule_kind"];
  const enabled = body["enabled"];
  const localTime = body["local_time"];
  if (typeof scheduleKind !== "string" || !SCHEDULE_KINDS.includes(scheduleKind)) {
    throw new FamilyOpsError("INVALID_INPUT", `schedule_kind must be one of ${SCHEDULE_KINDS.join(", ")}`, 400);
  }
  if (typeof enabled !== "boolean") {
    throw new FamilyOpsError("INVALID_INPUT", "enabled must be a boolean", 400);
  }
  if (typeof localTime !== "string" || localTime.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "local_time is required", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ ok: true }>(
    serviceClient,
    "server_tx_update_routine_schedule",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_schedule_kind: scheduleKind,
      p_enabled: enabled,
      p_local_time: localTime,
    },
  );

  return jsonResponse(result);
}));
