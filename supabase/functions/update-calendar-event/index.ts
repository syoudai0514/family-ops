// verify_jwt=true. docs/design/v6/07_GOOGLE_CALENDAR.md #12 "Update
// idempotency/concurrency — PATCH only". Not wrapped in
// withUserMutationHandler for the same reason as create-calendar-event: it
// can raise WP7-only codes (CALENDAR_ETAG_CONFLICT, CALENDAR_REAUTH_REQUIRED,
// CALENDAR_EVENT_NOT_FOUND) that errors.ts has no status mapping for.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { handlePreflight } from "../_shared/cors.ts";
import { jsonResponse } from "../_shared/handler.ts";
import { readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import {
  callGoogleServerTx,
  getAccessTokenForConnection,
  getEvent,
  GoogleInvalidGrantError,
  isRetryableGoogleWriteStatus,
  patchEvent,
  toGoogleErrorResponse,
} from "../_shared/googleCalendar.ts";
import { decryptRefreshToken, sha256Hex } from "../_shared/cryptoHelper.ts";
import { alreadyMatches, buildPatchBody, parsePatchFields } from "./patchFields.ts";

function stableStringify(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (value && typeof value === "object") {
    const keys = Object.keys(value as Record<string, unknown>).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${stableStringify((value as Record<string, unknown>)[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  try {
    const actorId = await requireUserActor(req);
    const body = await readJsonBody(req);
    const operationId = requireOperationId(body);

    const calendarConnectionId = body["calendar_connection_id"];
    const googleEventId = body["google_event_id"];
    if (typeof calendarConnectionId !== "string" || calendarConnectionId.length === 0) {
      throw new FamilyOpsError("INVALID_INPUT", "calendar_connection_id is required", 400);
    }
    if (typeof googleEventId !== "string" || googleEventId.length === 0) {
      throw new FamilyOpsError("INVALID_INPUT", "google_event_id is required", 400);
    }
    const fields = parsePatchFields(body);
    if (Object.keys(fields).length === 0) {
      throw new FamilyOpsError("INVALID_INPUT", "at least one field to update is required", 400);
    }

    const requestHash = await sha256Hex(stableStringify({ google_event_id: googleEventId, fields }));
    const serviceClient = createServiceRoleClient();

    const claim = await callGoogleServerTx<{ google_event_id: string; status: string; result_etag: string | null }>(
      serviceClient,
      "server_tx_claim_google_write",
      {
        p_actor_id: actorId,
        p_operation_id: operationId,
        p_calendar_connection_id: calendarConnectionId,
        p_action: "update",
        p_request_hash: requestHash,
        p_target_google_event_id: googleEventId,
      },
    );

    if (claim.status === "succeeded") {
      return jsonResponse({ google_event_id: claim.google_event_id, status: "succeeded", etag: claim.result_etag });
    }
    if (claim.status === "conflict") {
      throw new FamilyOpsError("CALENDAR_ETAG_CONFLICT", "予定が他の場所で更新されています。最新の内容を確認してください", 409);
    }
    if (claim.status === "dead") {
      throw new FamilyOpsError("INTERNAL_ERROR", "内部エラーが発生しました", 500);
    }

    let accessToken: string;
    let externalCalendarId: string;
    try {
      const conn = await getAccessTokenForConnection(serviceClient, calendarConnectionId, decryptRefreshToken);
      accessToken = conn.accessToken;
      externalCalendarId = conn.externalCalendarId;
    } catch (err) {
      if (err instanceof GoogleInvalidGrantError) {
        await callGoogleServerTx(serviceClient, "server_tx_mark_google_reauth_required", {
          p_calendar_connection_id: calendarConnectionId,
          p_reason: "invalid_grant during update",
        });
        throw new FamilyOpsError("CALENDAR_REAUTH_REQUIRED", "Googleカレンダー連携の再認証が必要です", 409);
      }
      throw err;
    }

    // #12 step 1-2: GET current remote event + etag before building the PATCH.
    const current = await getEvent({ accessToken, calendarId: externalCalendarId, eventId: googleEventId });
    if (current.status === 404 || !current.body || !current.etag) {
      await callGoogleServerTx(serviceClient, "server_tx_finalize_google_write", {
        p_operation_id: operationId,
        p_status: "dead",
        p_result_etag: null,
        p_last_error: "target event not found",
      });
      throw new FamilyOpsError("CALENDAR_EVENT_NOT_FOUND", "対象の予定が見つかりません", 404);
    }

    const existingPrivate = (current.body["extendedProperties"] as { private?: Record<string, string> } | undefined)?.private;
    const patchBody = buildPatchBody(fields, existingPrivate);

    let patchStatus: number;
    let patchResultBody: Record<string, unknown> | null;
    try {
      const res = await patchEvent({ accessToken, calendarId: externalCalendarId, eventId: googleEventId, body: patchBody, ifMatchEtag: current.etag });
      patchStatus = res.status;
      patchResultBody = res.body;
    } catch (_networkErr) {
      // Timeout: GET remote and reconcile before deciding (#12 "Timeout").
      const reconciled = await getEvent({ accessToken, calendarId: externalCalendarId, eventId: googleEventId });
      if (reconciled.body && alreadyMatches(fields, reconciled.body)) {
        await callGoogleServerTx(serviceClient, "server_tx_finalize_google_write", {
          p_operation_id: operationId,
          p_status: "succeeded",
          p_result_etag: reconciled.etag,
          p_last_error: null,
        });
        return jsonResponse({ google_event_id: googleEventId, status: "succeeded", etag: reconciled.etag });
      }
      throw new FamilyOpsError("CALENDAR_UNAVAILABLE", "カレンダーへの接続が一時的に失敗しました。もう一度お試しください", 503);
    }

    if (patchStatus === 200) {
      const etag = (patchResultBody?.etag as string | undefined) ?? null;
      await callGoogleServerTx(serviceClient, "server_tx_finalize_google_write", {
        p_operation_id: operationId,
        p_status: "succeeded",
        p_result_etag: etag,
        p_last_error: null,
      });
      await callGoogleServerTx(serviceClient, "server_tx_enqueue_google_sync", {
        p_calendar_connection_id: calendarConnectionId,
        p_reason: "write",
      }).catch(() => {});
      return jsonResponse({ google_event_id: googleEventId, status: "succeeded", etag });
    }

    if (patchStatus === 412) {
      // #12 step "412": GET latest; already-desired owned fields => success,
      // otherwise CALENDAR_ETAG_CONFLICT. Never a blind overwrite/retry.
      const latest = await getEvent({ accessToken, calendarId: externalCalendarId, eventId: googleEventId });
      if (latest.body && alreadyMatches(fields, latest.body)) {
        await callGoogleServerTx(serviceClient, "server_tx_finalize_google_write", {
          p_operation_id: operationId,
          p_status: "succeeded",
          p_result_etag: latest.etag,
          p_last_error: null,
        });
        return jsonResponse({ google_event_id: googleEventId, status: "succeeded", etag: latest.etag });
      }
      await callGoogleServerTx(serviceClient, "server_tx_finalize_google_write", {
        p_operation_id: operationId,
        p_status: "conflict",
        p_result_etag: null,
        p_last_error: "412 etag conflict",
      });
      throw new FamilyOpsError("CALENDAR_ETAG_CONFLICT", "予定が他の場所で更新されています。最新の内容を確認してください", 409);
    }

    if (isRetryableGoogleWriteStatus(patchStatus)) {
      // Leave the claimed operation pending so retrying the same operation_id
      // can recover from a provider outage or rate limit.
      throw new FamilyOpsError("CALENDAR_UNAVAILABLE", "カレンダーへの接続が一時的に失敗しました。もう一度お試しください", 503);
    }

    await callGoogleServerTx(serviceClient, "server_tx_finalize_google_write", {
      p_operation_id: operationId,
      p_status: "dead",
      p_result_etag: null,
      p_last_error: `patchEvent returned ${patchStatus}`,
    });
    throw new FamilyOpsError("INTERNAL_ERROR", "カレンダーの予定更新に失敗しました", 500);
  } catch (err) {
    return toGoogleErrorResponse(err);
  }
});
