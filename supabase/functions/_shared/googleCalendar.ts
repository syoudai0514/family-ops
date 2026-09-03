// Google Calendar API + OAuth wire helpers shared by every google-calendar-*
// / *-calendar-event Edge Function. docs/design/v6/07_GOOGLE_CALENDAR.md.
//
// New file (not an edit to any existing _shared/*.ts) per this work
// package's collision-avoidance constraints.
//
// GOOGLE_CALENDAR_CLIENT_ID / GOOGLE_CALENDAR_CLIENT_SECRET are real secrets
// that do not exist in this dev environment; referenced by name only, never
// fabricated. This Calendar OAuth client is separate from Supabase Auth's
// Google Sign-In client (#2 "App login and Calendar OAuth are separate") —
// never reuse GOOGLE_SIGN_IN_* env vars here.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders } from "./cors.ts";
import { describeCode, FamilyOpsError, isKnownErrorCode, statusForCode } from "./errors.ts";

export const GOOGLE_OAUTH_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth";
export const GOOGLE_OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token";
export const GOOGLE_CALENDAR_API_BASE = "https://www.googleapis.com/calendar/v3";

// #2 "exact scopes ... only".
export const GOOGLE_CALENDAR_SCOPES = [
  "https://www.googleapis.com/auth/calendar.events",
  "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
] as const;

// ---------------------------------------------------------------------------
// Error codes new to this work package. errors.ts (an existing shared file
// this work package must not edit) has no entries for these, so
// errorResponse()/callServerTx's automatic HTTP_STATUS_BY_CODE lookup would
// silently downgrade every one of them to a generic 500. googleErrorResponse
// / callGoogleServerTx below carry an explicit status for exactly this set
// instead, while still deferring to the existing catalogue for every
// already-known code (INVALID_INPUT, NOT_HOUSEHOLD_MEMBER,
// CROSS_HOUSEHOLD_RESOURCE, IDEMPOTENCY_CONFLICT, ...). See
// docs/adr/0005-google-calendar-new-error-codes.md — a human should fold
// this table into errors.ts's HTTP_STATUS_BY_CODE/KNOWN_CODES/describeCode
// in a follow-up that isn't constrained to collision-safe new files.
export const GOOGLE_ERROR_STATUS: Record<string, number> = {
  GOOGLE_OAUTH_STATE_INVALID: 400,
  CALENDAR_TIMEZONE_UNSUPPORTED: 422,
  CALENDAR_NO_ELIGIBLE_CALENDAR: 422,
  CALENDAR_ETAG_CONFLICT: 409,
  CALENDAR_REAUTH_REQUIRED: 409,
  CALENDAR_UNAVAILABLE: 503,
  CALENDAR_EVENT_NOT_FOUND: 404,
  GOOGLE_SYNC_LEASE_LOST: 409,
};

export function googleErrorResponse(code: string, message: string, detail?: string): Response {
  const status = GOOGLE_ERROR_STATUS[code] ?? statusForCode(code);
  return new Response(
    JSON.stringify({ error: { code, message, ...(detail ? { detail } : {}) } }),
    { status, headers: { ...corsHeaders, "Content-Type": "application/json" } },
  );
}

// Same shape as _shared/rpc.ts's callServerTx, but also recognizes the
// WP7-only codes above so a specific RPC-raised code (e.g.
// CALENDAR_TIMEZONE_UNSUPPORTED) reaches the client instead of becoming a
// generic 500. Every pre-existing code still resolves through errors.ts.
export async function callGoogleServerTx<T = unknown>(
  client: SupabaseClient,
  fnName: string,
  args: Record<string, unknown>,
): Promise<T> {
  const { data, error } = await client.rpc(fnName, args);
  if (error) {
    const code = error.message?.trim() ?? "";
    if (code in GOOGLE_ERROR_STATUS) {
      throw new FamilyOpsError(code, code, GOOGLE_ERROR_STATUS[code]);
    }
    if (isKnownErrorCode(code)) {
      const detail = (error as { details?: string }).details?.trim() || undefined;
      throw new FamilyOpsError(code, describeCode(code), statusForCode(code), detail);
    }
    console.error("server_tx RPC failed", { fnName, message: error.message });
    throw new FamilyOpsError("INTERNAL_ERROR", "内部エラーが発生しました", 500);
  }
  return data as T;
}

// Converts any thrown error into a Response using googleErrorResponse for
// the WP7-specific codes and the standard errorResponse-equivalent shape for
// everything else, so every WP7 Edge Function can share one catch site
// without needing withUserMutationHandler to know about the new codes.
export function toGoogleErrorResponse(err: unknown): Response {
  if (err instanceof FamilyOpsError) {
    return googleErrorResponse(err.code, err.message, err.detail);
  }
  console.error("unhandled google-calendar function error", err);
  return googleErrorResponse("INTERNAL_ERROR", "内部エラーが発生しました");
}

// ---------------------------------------------------------------------------
// #7A Recurring occurrence identity (mirrors
// private.google_original_start_time_key / private.google_occurrence_key —
// kept in sync deliberately since the Edge Function computes the
// deterministic write id and canonical-sync request shape client-side
// before ever calling the RPC).
export function originalStartTimeKey(originalStartTime: { date?: string; dateTime?: string } | null | undefined): string | null {
  if (!originalStartTime) return null;
  if (originalStartTime.date) return `date:${originalStartTime.date}`;
  if (originalStartTime.dateTime) {
    const iso = new Date(originalStartTime.dateTime).toISOString().replace(/\.\d{3}Z$/, "Z");
    return `datetime:${iso}`;
  }
  return null;
}

export function occurrenceKey(eventId: string, recurringEventId: string | null | undefined, originalStartTime: { date?: string; dateTime?: string } | null | undefined): string {
  if (recurringEventId) {
    return `rec:${recurringEventId}:${originalStartTimeKey(originalStartTime) ?? "unknown"}`;
  }
  return `event:${eventId}`;
}

export function classificationSubjectId(eventId: string, recurringEventId: string | null | undefined): string {
  return recurringEventId ?? eventId;
}

// #11 "Create idempotency": 'fo' + operation UUID hex, hyphens stripped.
// Every hex digit is already inside Google's base32hex id charset
// (0-9a-v), so no re-encoding is needed. Mirrors
// private.google_deterministic_event_id exactly.
export function deterministicGoogleEventId(operationId: string): string {
  return "fo" + operationId.toLowerCase().replace(/-/g, "");
}

// ---------------------------------------------------------------------------
// OAuth
export function buildAuthorizationUrl(opts: { clientId: string; redirectUri: string; state: string }): string {
  const params = new URLSearchParams({
    client_id: opts.clientId,
    redirect_uri: opts.redirectUri,
    response_type: "code",
    access_type: "offline",
    prompt: "consent", // ensures a refresh_token is issued even on a re-consent.
    scope: GOOGLE_CALENDAR_SCOPES.join(" "),
    state: opts.state,
  });
  return `${GOOGLE_OAUTH_AUTHORIZE_URL}?${params.toString()}`;
}

interface TokenResponse {
  access_token: string;
  refresh_token?: string;
  expires_in: number;
  scope: string;
  token_type: string;
}

export async function exchangeCodeForTokens(opts: { code: string; clientId: string; clientSecret: string; redirectUri: string }): Promise<TokenResponse> {
  const res = await fetch(GOOGLE_OAUTH_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code: opts.code,
      client_id: opts.clientId,
      client_secret: opts.clientSecret,
      redirect_uri: opts.redirectUri,
      grant_type: "authorization_code",
    }),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`google token exchange failed: ${res.status} ${body}`);
  }
  return await res.json();
}

export class GoogleInvalidGrantError extends Error {}

// Calendar API 403 is deliberately distinct from invalid_grant at the token
// endpoint.  A 403 can be transient, so workers must re-read calendarList
// before deciding whether a connection has lost its eligibility.
export class GoogleCalendarApiError extends Error {
  constructor(
    readonly operation: string,
    readonly status: number,
    detail?: string,
  ) {
    super(`${operation} failed: ${status}${detail ? ` ${detail}` : ""}`);
  }
}

export function isGoogleCalendarForbiddenError(err: unknown): err is GoogleCalendarApiError {
  return err instanceof GoogleCalendarApiError && err.status === 403;
}

export async function refreshAccessToken(opts: { refreshToken: string; clientId: string; clientSecret: string }): Promise<TokenResponse> {
  const res = await fetch(GOOGLE_OAUTH_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      refresh_token: opts.refreshToken,
      client_id: opts.clientId,
      client_secret: opts.clientSecret,
      grant_type: "refresh_token",
    }),
  });
  if (!res.ok) {
    const body = await res.text();
    if (res.status === 400 && body.includes("invalid_grant")) {
      // #2 "Publishing status gate": expected/routine while the OAuth
      // consent screen is in Testing (7-day token lifetime) — callers must
      // treat this as "flip to reauth_required", not a transient failure to
      // retry forever.
      throw new GoogleInvalidGrantError(body);
    }
    throw new Error(`google token refresh failed: ${res.status} ${body}`);
  }
  return await res.json();
}

export interface CalendarListEntry {
  id: string;
  summary?: string;
  accessRole: string;
  timeZone?: string;
}

export async function listCalendarList(accessToken: string): Promise<CalendarListEntry[]> {
  const items: CalendarListEntry[] = [];
  let pageToken: string | undefined;
  do {
    const params = new URLSearchParams({ maxResults: "250" });
    if (pageToken) params.set("pageToken", pageToken);
    const res = await fetch(`${GOOGLE_CALENDAR_API_BASE}/users/me/calendarList?${params.toString()}`, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (!res.ok) throw new GoogleCalendarApiError("calendarList.list", res.status, await res.text());
    const body = await res.json();
    items.push(...(body.items ?? []));
    pageToken = body.nextPageToken;
  } while (pageToken);
  return items;
}

// #5A: writer(WithoutPrivateAccess)/owner + Asia/Tokyo only.  This returns
// every eligible entry intentionally: OAuth must register choices for the
// household, never silently turn the first Calendar API result into a write
// target.  Keep the Google id as the stable identity; summary is display-only.
export function listEligibleCalendarCandidates(items: CalendarListEntry[]): CalendarListEntry[] {
  const allowedRoles = new Set(["writerWithoutPrivateAccess", "writer", "owner"]);
  const seen = new Set<string>();
  return items.filter((item) => {
    if (!item.id || seen.has(item.id) || !allowedRoles.has(item.accessRole) || item.timeZone !== "Asia/Tokyo") {
      return false;
    }
    seen.add(item.id);
    return true;
  });
}

// One live predicate for OAuth completion, explicit target selection, watch
// renewal, and 403 recovery.  Calendar titles are presentation-only; the
// stable Google calendar id is the only identity used here.
export async function isLiveCalendarEligible(accessToken: string, externalCalendarId: string): Promise<boolean> {
  const candidates = listEligibleCalendarCandidates(await listCalendarList(accessToken));
  return candidates.some((candidate) => candidate.id === externalCalendarId);
}

export async function recordGoogleCalendarEligibility(
  client: SupabaseClient,
  opts: { calendarConnectionId: string; eligible: boolean; reason: string },
): Promise<{ eligible: boolean }> {
  return await callGoogleServerTx<{ eligible: boolean }>(client, "server_tx_revalidate_google_calendar_eligibility", {
    p_calendar_connection_id: opts.calendarConnectionId,
    p_is_eligible: opts.eligible,
    p_reason: opts.reason,
  });
}

// Re-check exactly the same eligibility predicate used at OAuth completion.
// It never marks reauth_required: only invalid_grant means the household
// credential itself needs a new OAuth grant.
export async function revalidateCalendarEligibilityAfterForbidden(
  client: SupabaseClient,
  opts: { calendarConnectionId: string; externalCalendarId: string; accessToken: string; reason: string },
): Promise<{ eligible: boolean } | null> {
  try {
    const eligible = await isLiveCalendarEligible(opts.accessToken, opts.externalCalendarId);
    return await recordGoogleCalendarEligibility(client, {
      calendarConnectionId: opts.calendarConnectionId,
      eligible,
      reason: opts.reason,
    });
  } catch (err) {
    // A failed recheck is intentionally non-destructive.  The original 403
    // remains a normal retryable provider error until eligibility is proven
    // lost by calendarList.
    console.error("google calendar eligibility recheck failed", err);
    return null;
  }
}

interface EventsListPage {
  items: Record<string, unknown>[];
  nextPageToken?: string;
  nextSyncToken?: string;
}

// #6 "Canonical incremental sync — exact query contract": fixed parameter
// set, no timeMin/timeMax/orderBy/q/updatedMin/*ExtendedProperty ever added.
export async function listCanonicalEventsPage(opts: {
  accessToken: string;
  calendarId: string;
  syncToken?: string | null;
  pageToken?: string | null;
}): Promise<EventsListPage> {
  const params = new URLSearchParams({
    singleEvents: "false",
    showDeleted: "true",
    maxResults: "2500",
  });
  if (opts.syncToken) params.set("syncToken", opts.syncToken);
  if (opts.pageToken) params.set("pageToken", opts.pageToken);
  const res = await fetch(`${GOOGLE_CALENDAR_API_BASE}/calendars/${encodeURIComponent(opts.calendarId)}/events?${params.toString()}`, {
    headers: { Authorization: `Bearer ${opts.accessToken}` },
  });
  if (res.status === 410) {
    const err = new Error("google sync token expired (410 Gone)");
    (err as Error & { status?: number }).status = 410;
    throw err;
  }
  if (!res.ok) throw new GoogleCalendarApiError("events.list (canonical)", res.status, await res.text());
  const body = await res.json();
  return { items: body.items ?? [], nextPageToken: body.nextPageToken, nextSyncToken: body.nextSyncToken };
}

// #8 "Rolling occurrence projection": separate fixed parameter set, no
// syncToken ever, Google performs recurrence expansion.
export async function listProjectionEventsPage(opts: {
  accessToken: string;
  calendarId: string;
  timeMinRfc3339: string;
  timeMaxRfc3339: string;
  pageToken?: string | null;
}): Promise<EventsListPage> {
  const params = new URLSearchParams({
    singleEvents: "true",
    showDeleted: "false",
    orderBy: "startTime",
    maxResults: "2500",
    timeMin: opts.timeMinRfc3339,
    timeMax: opts.timeMaxRfc3339,
  });
  if (opts.pageToken) params.set("pageToken", opts.pageToken);
  const res = await fetch(`${GOOGLE_CALENDAR_API_BASE}/calendars/${encodeURIComponent(opts.calendarId)}/events?${params.toString()}`, {
    headers: { Authorization: `Bearer ${opts.accessToken}` },
  });
  if (!res.ok) throw new GoogleCalendarApiError("events.list (projection)", res.status, await res.text());
  const body = await res.json();
  return { items: body.items ?? [], nextPageToken: body.nextPageToken };
}

// Rolling window default: past 7d / future 60d, Asia/Tokyo boundaries
// converted to RFC3339 UTC (#8).
export function projectionWindow(now = new Date()): { start: string; end: string; startDate: string; endDate: string } {
  const start = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);
  const end = new Date(now.getTime() + 60 * 24 * 60 * 60 * 1000);
  const asDate = (d: Date) => d.toISOString().slice(0, 10);
  return { start: start.toISOString(), end: end.toISOString(), startDate: asDate(start), endDate: asDate(end) };
}

export type GoogleEventGetResult =
  | { status: 404; body: null; etag: null }
  | { status: 200; body: Record<string, unknown>; etag: string };

export async function getEvent(opts: { accessToken: string; calendarId: string; eventId: string }): Promise<GoogleEventGetResult> {
  const res = await fetch(`${GOOGLE_CALENDAR_API_BASE}/calendars/${encodeURIComponent(opts.calendarId)}/events/${encodeURIComponent(opts.eventId)}`, {
    headers: { Authorization: `Bearer ${opts.accessToken}` },
  });
  if (res.status === 404) return { status: 404, body: null, etag: null };
  if (!res.ok) throw new GoogleCalendarApiError("events.get", res.status, await res.text());
  const body = await res.json() as Record<string, unknown>;
  const rawEtag = body.etag;
  const etag = typeof rawEtag === "string" ? rawEtag.trim() : "";
  // DD8 safety: every existing provider identity used by PATCH/DELETE must
  // carry an ETag. A malformed 200 response is not allowed to degrade a
  // conditional mutation into an unconditional one. This happens before the
  // worker establishes a provider-mutation authorization fence.
  if (!etag) throw new GoogleCalendarApiError("events.get missing ETag", 502);
  return { status: 200, body, etag };
}

// #11 create: sendUpdates='none', deterministic id supplied by the caller.
export async function insertEvent(opts: { accessToken: string; calendarId: string; body: Record<string, unknown> }): Promise<{ status: number; body: Record<string, unknown> | null }> {
  const res = await fetch(`${GOOGLE_CALENDAR_API_BASE}/calendars/${encodeURIComponent(opts.calendarId)}/events?sendUpdates=none`, {
    method: "POST",
    headers: { Authorization: `Bearer ${opts.accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify(opts.body),
  });
  const body = res.status === 204 ? null : await res.json().catch(() => null);
  return { status: res.status, body };
}

// #12 update: PATCH only, If-Match etag, sendUpdates='none'.
export async function patchEvent(opts: { accessToken: string; calendarId: string; eventId: string; body: Record<string, unknown>; ifMatchEtag: string }): Promise<{ status: number; body: Record<string, unknown> | null }> {
  const res = await fetch(`${GOOGLE_CALENDAR_API_BASE}/calendars/${encodeURIComponent(opts.calendarId)}/events/${encodeURIComponent(opts.eventId)}?sendUpdates=none`, {
    method: "PATCH",
    headers: {
      Authorization: `Bearer ${opts.accessToken}`,
      "Content-Type": "application/json",
      "If-Match": opts.ifMatchEtag,
    },
    body: JSON.stringify(opts.body),
  });
  const body = res.status === 204 ? null : await res.json().catch(() => null);
  return { status: res.status, body };
}

// A generated mirror is removed only by its stored provider_event_id. This
// intentionally has no search/query variant: titles and dates are display
// data, never provider identity. If-Match is mandatory: there is no source
// path that may emit an unconditional DELETE for an existing event.
export async function deleteEvent(opts: { accessToken: string; calendarId: string; eventId: string; ifMatchEtag: string }): Promise<number> {
  const etag = opts.ifMatchEtag.trim();
  if (!etag) throw new GoogleCalendarApiError("events.delete missing If-Match ETag", 409);
  const res = await fetch(`${GOOGLE_CALENDAR_API_BASE}/calendars/${encodeURIComponent(opts.calendarId)}/events/${encodeURIComponent(opts.eventId)}?sendUpdates=none`, {
    method: "DELETE",
    headers: {
      Authorization: `Bearer ${opts.accessToken}`,
      "If-Match": etag,
    },
  });
  return res.status;
}

export async function createWatchChannel(opts: { accessToken: string; calendarId: string; channelId: string; token: string; webhookUrl: string }): Promise<{ resourceId: string; expiration: number }> {
  const res = await fetch(`${GOOGLE_CALENDAR_API_BASE}/calendars/${encodeURIComponent(opts.calendarId)}/events/watch`, {
    method: "POST",
    headers: { Authorization: `Bearer ${opts.accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ id: opts.channelId, type: "web_hook", address: opts.webhookUrl, token: opts.token }),
  });
  if (!res.ok) throw new GoogleCalendarApiError("events.watch", res.status, await res.text());
  const body = await res.json();
  return { resourceId: body.resourceId, expiration: Number(body.expiration) };
}

export async function stopWatchChannel(opts: { accessToken: string; channelId: string; resourceId: string }): Promise<void> {
  const res = await fetch(`${GOOGLE_CALENDAR_API_BASE}/channels/stop`, {
    method: "POST",
    headers: { Authorization: `Bearer ${opts.accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ id: opts.channelId, resourceId: opts.resourceId }),
  });
  if (!res.ok && res.status !== 404) {
    throw new GoogleCalendarApiError("channels.stop", res.status, await res.text());
  }
}

// Shared by every worker/write Edge Function that needs to actually call
// the Calendar API for one calendar_connection_id: fetches the encrypted
// credential + target calendar id via server_tx_get_google_sync_context,
// decrypts, and exchanges the refresh token for a fresh access token. On
// invalid_grant the caller is expected to catch GoogleInvalidGrantError and
// call server_tx_mark_google_reauth_required.
export async function getAccessTokenForConnection(
  client: SupabaseClient,
  calendarConnectionId: string,
  decryptRefreshToken: (ciphertext: string, version: number) => Promise<string>,
): Promise<{ accessToken: string; externalCalendarId: string; householdId: string }> {
  const context = await callGoogleServerTx<{
    external_calendar_id: string;
    household_id: string;
    encrypted_refresh_token: string;
    encryption_version: number;
  }>(client, "server_tx_get_google_sync_context", { p_calendar_connection_id: calendarConnectionId });

  if (!context || !context.encrypted_refresh_token) {
    throw new FamilyOpsError("CALENDAR_REAUTH_REQUIRED", "Googleカレンダー連携の再認証が必要です", 409);
  }

  const clientId = Deno.env.get("GOOGLE_CALENDAR_CLIENT_ID");
  const clientSecret = Deno.env.get("GOOGLE_CALENDAR_CLIENT_SECRET");
  if (!clientId || !clientSecret) {
    throw new Error("GOOGLE_CALENDAR_CLIENT_ID / GOOGLE_CALENDAR_CLIENT_SECRET not configured");
  }

  const refreshToken = await decryptRefreshToken(context.encrypted_refresh_token, context.encryption_version);
  const tokens = await refreshAccessToken({ refreshToken, clientId, clientSecret });

  return { accessToken: tokens.access_token, externalCalendarId: context.external_calendar_id, householdId: context.household_id };
}

// Merges caller-owned extendedProperties.private keys into whatever the
// remote event already carries, preserving unrelated keys (#12 step 4).
export function mergePrivateExtendedProperties(
  existing: Record<string, string> | undefined,
  toSet: Record<string, string>,
): Record<string, string> {
  return { ...(existing ?? {}), ...toSet };
}
