// verify_jwt=true. A target switch verifies the candidate against Google's
// current calendarList before the database mutation can clear any old target.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import {
  callGoogleServerTx,
  getAccessTokenForConnection,
  GoogleInvalidGrantError,
  isLiveCalendarEligible,
  recordGoogleCalendarEligibility,
} from "../_shared/googleCalendar.ts";
import { decryptRefreshToken } from "../_shared/cryptoHelper.ts";
import { readJsonBody, requireOperationId } from "../_shared/rpc.ts";

interface TargetCandidate {
  calendar_connection_id: string;
  external_calendar_id: string;
}

Deno.serve(withUserMutationHandler(async (req) => {
  const body = await readJsonBody(req);
  const calendarConnectionId = body.calendar_connection_id;
  if (typeof calendarConnectionId !== "string" || calendarConnectionId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "calendar_connection_id is required", 400);
  }

  const actorId = await requireUserActor(req);
  const operationId = requireOperationId(body);
  const serviceClient = createServiceRoleClient();

  // Authorize and resolve only the new candidate first. This is intentionally
  // not server_tx_set_family_calendar_target: a provider failure must leave
  // the old target untouched.
  const candidate = await callGoogleServerTx<TargetCandidate>(
    serviceClient,
    "server_tx_get_google_calendar_target_candidate",
    { p_actor_id: actorId, p_calendar_connection_id: calendarConnectionId },
  );

  let accessToken: string;
  try {
    const connection = await getAccessTokenForConnection(
      serviceClient,
      candidate.calendar_connection_id,
      decryptRefreshToken,
    );
    accessToken = connection.accessToken;
  } catch (err) {
    if (err instanceof GoogleInvalidGrantError) {
      await callGoogleServerTx(serviceClient, "server_tx_mark_google_reauth_required", {
        p_calendar_connection_id: candidate.calendar_connection_id,
        p_reason: "invalid_grant during family calendar target selection",
      });
      throw new FamilyOpsError("CALENDAR_REAUTH_REQUIRED", "Googleカレンダー連携の再認証が必要です", 409);
    }
    throw err;
  }

  let eligible: boolean;
  try {
    eligible = await isLiveCalendarEligible(accessToken, candidate.external_calendar_id);
  } catch {
    // A calendarList failure proves neither eligibility nor ineligibility, so
    // do not mutate a target. A later 403 on sync/write remains protected by
    // the separate revalidation path.
    throw new FamilyOpsError("CALENDAR_UNAVAILABLE", "Googleカレンダーを確認できませんでした。しばらくしてから再度お試しください", 503);
  }

  if (!eligible) {
    // This marks only the requested candidate inactive/unselected. The
    // household's previous target is never touched by a failed target switch.
    await recordGoogleCalendarEligibility(serviceClient, {
      calendarConnectionId: candidate.calendar_connection_id,
      eligible: false,
      reason: "target selection rejected by live calendarList eligibility",
    });
    throw new FamilyOpsError("CALENDAR_NO_ELIGIBLE_CALENDAR", "選択したカレンダーは書き込み先に利用できません", 422);
  }

  return jsonResponse(await callGoogleServerTx(serviceClient, "server_tx_set_family_calendar_target", {
    p_actor_id: actorId,
    p_operation_id: operationId,
    p_calendar_connection_id: candidate.calendar_connection_id,
  }));
}));
