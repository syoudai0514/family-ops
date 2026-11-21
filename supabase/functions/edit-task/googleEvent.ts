import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { decryptRefreshToken } from "../_shared/cryptoHelper.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import { getAccessTokenForConnection, getEvent, patchEvent } from "../_shared/googleCalendar.ts";

const googleProvider = { getAccessTokenForConnection, getEvent, patchEvent };

export async function googleEventCommand(client: SupabaseClient, actorId: string, body: Record<string, unknown>, provider = googleProvider) {
  const occurrenceId = body.occurrence_id;
  if (typeof occurrenceId !== "string") throw new FamilyOpsError("INVALID_INPUT", "予定を確認できませんでした。", 400);
  const member = await client.from("household_members").select("household_id").eq("user_id", actorId).maybeSingle();
  if (member.error || !member.data) throw new FamilyOpsError("NOT_HOUSEHOLD_MEMBER", "家庭情報を確認できませんでした。", 403);
  const occurrence = await client.from("calendar_event_occurrences")
    .select("google_event_id,calendar_connection_id,family_ops_mirror,calendar_connections!inner(active,is_family_write_target)")
    .eq("household_id", member.data.household_id).eq("id", occurrenceId).neq("status", "cancelled")
    .eq("calendar_connections.active", true).eq("calendar_connections.is_family_write_target", true).maybeSingle();
  if (occurrence.error || !occurrence.data) throw new FamilyOpsError("CALENDAR_EVENT_NOT_FOUND", "家族カレンダーの予定が見つかりません。", 404);

  if (occurrence.data.family_ops_mirror === true) throw new FamilyOpsError("INVALID_INPUT", "この予定はおうちノート側で編集してください。", 400);
  const connectionId = occurrence.data.calendar_connection_id as string;
  const eventId = occurrence.data.google_event_id as string;
  const connection = await provider.getAccessTokenForConnection(client, connectionId, decryptRefreshToken);
  if (connection.householdId !== member.data.household_id) throw new FamilyOpsError("CROSS_HOUSEHOLD_RESOURCE", "予定を確認できませんでした。", 403);
  const existing = await provider.getEvent({ accessToken: connection.accessToken, calendarId: connection.externalCalendarId, eventId });
  if (existing.status === 404) throw new FamilyOpsError("CALENDAR_EVENT_NOT_FOUND", "Googleカレンダーに予定が見つかりません。", 404);
  if (existing.body.status === "cancelled") throw new FamilyOpsError("CALENDAR_EVENT_NOT_FOUND", "Googleカレンダーに予定が見つかりません。", 404);
  const properties = existing.body.extendedProperties as { private?: Record<string, unknown> } | undefined;
  if (properties?.private?.familyOpsMirror === "true") throw new FamilyOpsError("INVALID_INPUT", "この予定はおうちノート側で編集してください。", 400);

  if (body.action === "read_google_event") {
    const start = existing.body.start as { date?: unknown; dateTime?: unknown } | undefined;
    const end = existing.body.end as { date?: unknown; dateTime?: unknown } | undefined;
    if (!start || !end || !((typeof start.date === "string" && typeof end.date === "string") ||
        (typeof start.dateTime === "string" && typeof end.dateTime === "string" &&
         Number.isFinite(Date.parse(start.dateTime)) && Number.isFinite(Date.parse(end.dateTime))))) {
      throw new FamilyOpsError("CALENDAR_UNAVAILABLE", "予定の日時を読み込めませんでした。Google側で確認してください。", 503);
    }
    return {
      etag: existing.etag,
      title: typeof existing.body.summary === "string" ? existing.body.summary : "",
      description: typeof existing.body.description === "string" ? existing.body.description : "",
      location: typeof existing.body.location === "string" ? existing.body.location : "",
      start: existing.body.start,
      end: existing.body.end,
      recurring: typeof existing.body.recurringEventId === "string",
    };
  }
  if (body.action !== "save_google_event" || typeof body.etag !== "string" || !body.etag) {
    throw new FamilyOpsError("INVALID_INPUT", "編集内容を確認してください。", 400);
  }
  if (body.etag !== existing.etag) throw new FamilyOpsError("CALENDAR_ETAG_CONFLICT", "Google側で予定が変更されました。開き直して確認してください。", 409);
  const patch = validateGooglePatch(body.changes);
  const result = await provider.patchEvent({ accessToken: connection.accessToken, calendarId: connection.externalCalendarId, eventId, body: patch, ifMatchEtag: existing.etag });
  if (result.status === 412) throw new FamilyOpsError("CALENDAR_ETAG_CONFLICT", "Google側で予定が変更されました。開き直して確認してください。", 409);
  if (result.status === 403) throw new FamilyOpsError("CALENDAR_UNAVAILABLE", "このカレンダーを編集する権限を確認してください。", 403);
  if (result.status !== 200) throw new FamilyOpsError("CALENDAR_UNAVAILABLE", "Googleカレンダーへ保存できませんでした。", 503);
  let syncRequested = false;
  try {
    const queued = await client.rpc("server_tx_enqueue_google_sync", { p_calendar_connection_id: connectionId, p_reason: "pwa_event_edit" });
    syncRequested = !queued.error;
  } catch {
    // Google already accepted the change. Preserve that outcome if queueing fails.
  }
  return { saved: true, syncRequested };
}

export function validateGooglePatch(input: unknown): Record<string, unknown> {
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new FamilyOpsError("INVALID_INPUT", "編集内容を確認してください。", 400);
  const changes = input as Record<string, unknown>;
  const allowed = ["summary", "location", "description", "start", "end"];
  if (Object.keys(changes).some((key) => !allowed.includes(key))) throw new FamilyOpsError("INVALID_INPUT", "編集内容を確認してください。", 400);
  const patch: Record<string, unknown> = {};
  for (const key of ["summary", "location", "description"]) {
    if (changes[key] === undefined) continue;
    if (typeof changes[key] !== "string" || (changes[key] as string).length > 8000 || (key === "summary" && !(changes[key] as string).trim())) {
      throw new FamilyOpsError("INVALID_INPUT", "予定名と内容を確認してください。", 400);
    }
    patch[key] = changes[key];
  }
  if (changes.start !== undefined || changes.end !== undefined) {
    const start = changes.start as Record<string, unknown> | undefined;
    const end = changes.end as Record<string, unknown> | undefined;
    if (!start || !end || typeof start !== "object" || typeof end !== "object") throw new FamilyOpsError("INVALID_INPUT", "開始と終了を確認してください。", 400);
    const dateOnly = typeof start.date === "string" && typeof end.date === "string";
    const startValue = dateOnly ? start.date : start.dateTime;
    const endValue = dateOnly ? end.date : end.dateTime;
    const datePattern = /^\d{4}-\d{2}-\d{2}$/;
    const timePattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00\+09:00$/;
    const pattern = dateOnly ? datePattern : timePattern;
    const validDate = (value: string) => {
      const date = value.slice(0, 10);
      const stamp = Date.parse(`${date}T00:00:00Z`);
      return Number.isFinite(stamp) && new Date(stamp).toISOString().slice(0, 10) === date;
    };
    if (typeof startValue !== "string" || typeof endValue !== "string" || !pattern.test(startValue) || !pattern.test(endValue) ||
        !validDate(startValue) || !validDate(endValue) || !Number.isFinite(Date.parse(startValue)) || !Number.isFinite(Date.parse(endValue)) || Date.parse(endValue) <= Date.parse(startValue)) {
      throw new FamilyOpsError("INVALID_INPUT", "終了は開始より後にしてください。", 400);
    }
    patch.start = dateOnly ? { date: startValue } : { dateTime: startValue, timeZone: "Asia/Tokyo" };
    patch.end = dateOnly ? { date: endValue } : { dateTime: endValue, timeZone: "Asia/Tokyo" };
  }
  if (!Object.keys(patch).length) throw new FamilyOpsError("INVALID_INPUT", "変更する内容がありません。", 400);
  return patch;
}
