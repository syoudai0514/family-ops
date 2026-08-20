// verify_jwt=true. docs/design/v6/07_GOOGLE_CALENDAR.md #8 "Manual busy
// classification persistence", #9 "PWA may later allow manual
// classification".
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import { callGoogleServerTx } from "../_shared/googleCalendar.ts";

const BUSY_SCOPES = ["self", "partner", "family", "unknown"];

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const calendarConnectionId = body["calendar_connection_id"];
  const subjectEventId = body["subject_event_id"];
  const originalStartTimeKey = body["original_start_time_key"];
  const busyScope = body["busy_scope"];
  const memberUserIds = body["member_user_ids"];

  if (typeof calendarConnectionId !== "string" || calendarConnectionId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "calendar_connection_id is required", 400);
  }
  if (typeof subjectEventId !== "string" || subjectEventId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "subject_event_id is required", 400);
  }
  if (originalStartTimeKey !== undefined && originalStartTimeKey !== null && typeof originalStartTimeKey !== "string") {
    throw new FamilyOpsError("INVALID_INPUT", "original_start_time_key must be a string", 400);
  }
  if (typeof busyScope !== "string" || !BUSY_SCOPES.includes(busyScope)) {
    throw new FamilyOpsError("INVALID_INPUT", "busy_scope is invalid", 400);
  }
  if (memberUserIds !== undefined && memberUserIds !== null) {
    if (!Array.isArray(memberUserIds) || memberUserIds.some((m) => typeof m !== "string")) {
      throw new FamilyOpsError("INVALID_INPUT", "member_user_ids must be an array of strings", 400);
    }
  }

  const serviceClient = createServiceRoleClient();
  const result = await callGoogleServerTx(serviceClient, "server_tx_classify_calendar_busy", {
    p_actor_id: actorId,
    p_operation_id: operationId,
    p_calendar_connection_id: calendarConnectionId,
    p_subject_event_id: subjectEventId,
    p_original_start_time_key: typeof originalStartTimeKey === "string" ? originalStartTimeKey : null,
    p_busy_scope: busyScope,
    p_member_user_ids: Array.isArray(memberUserIds) ? memberUserIds : null,
  });

  return jsonResponse(result);
}));
