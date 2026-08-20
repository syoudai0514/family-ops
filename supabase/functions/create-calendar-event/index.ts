// verify_jwt=true. docs/design/v6/07_GOOGLE_CALENDAR.md #11 "Create
// idempotency". Not wrapped in withUserMutationHandler/errorResponse
// (existing _shared files, unmodified here) because this path can raise
// WP7-only error codes (e.g. CALENDAR_REAUTH_REQUIRED) that errors.ts's
// HTTP_STATUS_BY_CODE has no entry for; toGoogleErrorResponse carries the
// right status for those while still deferring to the existing catalogue
// for every already-known code.
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
  insertEvent,
  toGoogleErrorResponse,
} from "../_shared/googleCalendar.ts";
import { decryptRefreshToken, sha256Hex } from "../_shared/cryptoHelper.ts";

interface EventInput {
  calendar_connection_id: string;
  title: string | null;
  description: string | null;
  location: string | null;
  start_date_time: string | null; // RFC3339, mutually exclusive with start_date
  end_date_time: string | null;
  start_date: string | null; // YYYY-MM-DD (all-day), exclusive end per Google convention
  end_date: string | null;
  busy_member_user_ids: string[]; // 自分/相手/家族/未指定 already resolved to concrete member ids by the caller; [] = 未指定
}

function stableStringify(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (value && typeof value === "object") {
    const keys = Object.keys(value as Record<string, unknown>).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${stableStringify((value as Record<string, unknown>)[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function parseInput(body: Record<string, unknown>): EventInput {
  const calendarConnectionId = body["calendar_connection_id"];
  if (typeof calendarConnectionId !== "string" || calendarConnectionId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "calendar_connection_id is required", 400);
  }
  const title = body["title"];
  if (title !== undefined && title !== null && typeof title !== "string") {
    throw new FamilyOpsError("INVALID_INPUT", "title must be a string or null", 400);
  }
  const startDateTime = body["start_date_time"];
  const endDateTime = body["end_date_time"];
  const startDate = body["start_date"];
  const endDate = body["end_date"];
  const hasTimed = typeof startDateTime === "string" && typeof endDateTime === "string";
  const hasAllDay = typeof startDate === "string" && typeof endDate === "string";
  if (hasTimed === hasAllDay) {
    throw new FamilyOpsError("INVALID_INPUT", "exactly one of start_date_time/end_date_time or start_date/end_date is required", 400);
  }
  const busyMemberUserIds = body["busy_member_user_ids"];
  if (busyMemberUserIds !== undefined && (!Array.isArray(busyMemberUserIds) || busyMemberUserIds.some((m) => typeof m !== "string"))) {
    throw new FamilyOpsError("INVALID_INPUT", "busy_member_user_ids must be an array of strings", 400);
  }

  return {
    calendar_connection_id: calendarConnectionId,
    title: typeof title === "string" ? title : null,
    description: typeof body["description"] === "string" ? (body["description"] as string) : null,
    location: typeof body["location"] === "string" ? (body["location"] as string) : null,
    start_date_time: hasTimed ? (startDateTime as string) : null,
    end_date_time: hasTimed ? (endDateTime as string) : null,
    start_date: hasAllDay ? (startDate as string) : null,
    end_date: hasAllDay ? (endDate as string) : null,
    busy_member_user_ids: Array.isArray(busyMemberUserIds) ? (busyMemberUserIds as string[]) : [],
  };
}

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  try {
    const actorId = await requireUserActor(req);
    const body = await readJsonBody(req);
    const operationId = requireOperationId(body);
    const input = parseInput(body);

    const requestHash = await sha256Hex(stableStringify(input));
    const serviceClient = createServiceRoleClient();

    const claim = await callGoogleServerTx<{ google_event_id: string; status: string; result_etag: string | null }>(
      serviceClient,
      "server_tx_claim_google_write",
      {
        p_actor_id: actorId,
        p_operation_id: operationId,
        p_calendar_connection_id: input.calendar_connection_id,
        p_action: "create",
        p_request_hash: requestHash,
        p_target_google_event_id: null,
      },
    );

    if (claim.status === "succeeded") {
      return jsonResponse({ google_event_id: claim.google_event_id, status: "succeeded", etag: claim.result_etag });
    }
    if (claim.status === "conflict") {
      throw new FamilyOpsError("IDEMPOTENCY_CONFLICT", "同じ操作IDで異なる内容が送信されました", 409);
    }
    if (claim.status === "dead") {
      throw new FamilyOpsError("INTERNAL_ERROR", "内部エラーが発生しました", 500);
    }

    let accessToken: string;
    let externalCalendarId: string;
    try {
      const conn = await getAccessTokenForConnection(serviceClient, input.calendar_connection_id, decryptRefreshToken);
      accessToken = conn.accessToken;
      externalCalendarId = conn.externalCalendarId;
    } catch (err) {
      if (err instanceof GoogleInvalidGrantError) {
        await callGoogleServerTx(serviceClient, "server_tx_mark_google_reauth_required", {
          p_calendar_connection_id: input.calendar_connection_id,
          p_reason: "invalid_grant during create",
        });
        throw new FamilyOpsError("CALENDAR_REAUTH_REQUIRED", "Googleカレンダー連携の再認証が必要です", 409);
      }
      throw err;
    }

    const eventBody: Record<string, unknown> = {
      id: claim.google_event_id,
      summary: input.title ?? undefined,
      description: input.description ?? undefined,
      location: input.location ?? undefined,
      start: input.start_date_time
        ? { dateTime: input.start_date_time, timeZone: "Asia/Tokyo" }
        : { date: input.start_date },
      end: input.end_date_time
        ? { dateTime: input.end_date_time, timeZone: "Asia/Tokyo" }
        : { date: input.end_date },
      extendedProperties: {
        private: {
          familyOpsOperationId: operationId,
          ...(input.busy_member_user_ids.length > 0 ? { familyOpsBusyMemberIds: input.busy_member_user_ids.join(",") } : {}),
        },
      },
    };

    let insertStatus: number;
    let insertBody: Record<string, unknown> | null;
    try {
      const res = await insertEvent({ accessToken, calendarId: externalCalendarId, body: eventBody });
      insertStatus = res.status;
      insertBody = res.body;
    } catch (_networkErr) {
      // #11 "response lost": the provider call itself failed to complete
      // (timeout/network error, not a structured HTTP error response).
      // Reconcile by GET before deciding anything.
      const existing = await getEvent({ accessToken, calendarId: externalCalendarId, eventId: claim.google_event_id });
      if (existing.status === 200 && existing.body) {
        await callGoogleServerTx(serviceClient, "server_tx_finalize_google_write", {
          p_operation_id: operationId,
          p_status: "succeeded",
          p_result_etag: existing.etag,
          p_last_error: null,
        });
        return jsonResponse({ google_event_id: claim.google_event_id, status: "succeeded", etag: existing.etag });
      }
      // Still not landed: leave status pending so a client retry (same
      // operation_id) tries the provider call again.
      throw new FamilyOpsError("CALENDAR_UNAVAILABLE", "カレンダーへの接続が一時的に失敗しました。もう一度お試しください", 503);
    }

    if (insertStatus === 200 || insertStatus === 201) {
      const etag = (insertBody?.etag as string | undefined) ?? null;
      await callGoogleServerTx(serviceClient, "server_tx_finalize_google_write", {
        p_operation_id: operationId,
        p_status: "succeeded",
        p_result_etag: etag,
        p_last_error: null,
      });
      await callGoogleServerTx(serviceClient, "server_tx_enqueue_google_sync", {
        p_calendar_connection_id: input.calendar_connection_id,
        p_reason: "write",
      }).catch(() => {});
      return jsonResponse({ google_event_id: claim.google_event_id, status: "succeeded", etag });
    }

    if (insertStatus === 409) {
      // #11 "409 duplicate": GET the same id and verify the operation marker.
      const existing = await getEvent({ accessToken, calendarId: externalCalendarId, eventId: claim.google_event_id });
      const remoteOperationId = existing.body
        ? ((existing.body["extendedProperties"] as { private?: Record<string, string> } | undefined)?.private?.["familyOpsOperationId"])
        : undefined;
      if (existing.status === 200 && remoteOperationId === operationId) {
        await callGoogleServerTx(serviceClient, "server_tx_finalize_google_write", {
          p_operation_id: operationId,
          p_status: "succeeded",
          p_result_etag: existing.etag,
          p_last_error: null,
        });
        return jsonResponse({ google_event_id: claim.google_event_id, status: "succeeded", etag: existing.etag });
      }
      await callGoogleServerTx(serviceClient, "server_tx_finalize_google_write", {
        p_operation_id: operationId,
        p_status: "conflict",
        p_result_etag: null,
        p_last_error: "409 duplicate with mismatched or missing operation marker",
      });
      throw new FamilyOpsError("IDEMPOTENCY_CONFLICT", "同じ予定IDが既に別内容で存在します", 409);
    }

    await callGoogleServerTx(serviceClient, "server_tx_finalize_google_write", {
      p_operation_id: operationId,
      p_status: "dead",
      p_result_etag: null,
      p_last_error: `insertEvent returned ${insertStatus}`,
    });
    throw new FamilyOpsError("INTERNAL_ERROR", "カレンダーへの予定作成に失敗しました", 500);
  } catch (err) {
    return toGoogleErrorResponse(err);
  }
});
