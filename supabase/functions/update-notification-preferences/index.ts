// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #8/#19 "update-notification-preferences".
// Partial update: only the boolean fields present in the request body are
// changed; schedule times are a separate mutation (update-routine-schedule).
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

const ALLOWED_KEYS = [
  "request_line", "handover_line", "calendar_line", "conflict_line",
  "routine_completion_line", "shopping_minor_line", "weekly_digest_line",
  "daily_assignment_line", "routine_checklist_line", "routine_checkin_prompt_line",
  "in_app",
];

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const fields: Record<string, boolean> = {};
  for (const [key, value] of Object.entries(body)) {
    if (key === "operation_id") continue;
    if (!ALLOWED_KEYS.includes(key) || typeof value !== "boolean") {
      throw new FamilyOpsError("INVALID_INPUT", `unknown or invalid preference field: ${key}`, 400);
    }
    fields[key] = value;
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ ok: true }>(
    serviceClient,
    "server_tx_update_notification_preferences",
    { p_actor_id: actorId, p_operation_id: operationId, p_fields: fields },
  );

  return jsonResponse(result);
}));
