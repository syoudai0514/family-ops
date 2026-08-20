// verify_jwt=false — this is Google's own browser redirect back to the app,
// which never carries an Authorization header. Per
// docs/design/v6/07_GOOGLE_CALENDAR.md #2A step 4, the state row's stored
// household_id/user_id binding (not a JWT) is what's authoritative here.
// This is a distinct OAuth client/consent from Supabase Auth's Google
// Sign-In (#2 "App login and Calendar OAuth are separate") — it must never
// share client id/secret or redirect URI with that flow.
import { createServiceRoleClient } from "../_shared/auth.ts";
import {
  callGoogleServerTx,
  exchangeCodeForTokens,
  GoogleInvalidGrantError,
  listCalendarList,
  pickEligibleCalendar,
} from "../_shared/googleCalendar.ts";
import { encryptRefreshToken, sha256Hex } from "../_shared/cryptoHelper.ts";

function redirectTo(appBaseUrl: string, path: string, params: Record<string, string>): Response {
  const url = new URL(path, appBaseUrl);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  return new Response(null, { status: 302, headers: { Location: url.toString() } });
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  const appBaseUrl = Deno.env.get("APP_BASE_URL");
  if (!appBaseUrl) {
    // No safe redirect target at all — fail loud rather than guessing a host.
    return new Response("APP_BASE_URL not configured", { status: 500 });
  }

  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const providerError = url.searchParams.get("error");

  if (providerError) {
    return redirectTo(appBaseUrl, "/settings/calendar", { google_calendar_error: "access_denied" });
  }
  if (!code || !state) {
    return redirectTo(appBaseUrl, "/settings/calendar", { google_calendar_error: "invalid_request" });
  }

  const clientId = Deno.env.get("GOOGLE_CALENDAR_CLIENT_ID");
  const clientSecret = Deno.env.get("GOOGLE_CALENDAR_CLIENT_SECRET");
  const redirectUri = Deno.env.get("GOOGLE_CALENDAR_REDIRECT_URI");
  if (!clientId || !clientSecret || !redirectUri) {
    return new Response("GOOGLE_CALENDAR_CLIENT_ID/SECRET/REDIRECT_URI not configured", { status: 500 });
  }

  const serviceClient = createServiceRoleClient();

  try {
    const stateHash = await sha256Hex(state);

    const tokens = await exchangeCodeForTokens({ code, clientId, clientSecret, redirectUri });
    if (!tokens.refresh_token) {
      // prompt=consent should always yield one; without it we cannot store a
      // durable connection at all.
      return redirectTo(appBaseUrl, "/settings/calendar", { google_calendar_error: "no_refresh_token" });
    }

    // Best-effort subject identification: the connection only ever needs
    // scopes for calendar.events/calendarlist, never 'openid', so a
    // guaranteed `sub` claim is not available. Fall back to the eligible
    // calendar's id (Google secondary-calendar ids are stable, opaque
    // strings) — this is a display/bookkeeping value only, never a security
    // boundary (household/user binding is enforced by the state row + the
    // household_id composite FK, not by google_subject).
    const calendarItems = await listCalendarList(tokens.access_token);
    const eligible = pickEligibleCalendar(calendarItems);
    if (!eligible) {
      return redirectTo(appBaseUrl, "/settings/calendar", { google_calendar_error: "no_eligible_calendar" });
    }
    const googleSubject = eligible.id;

    const { ciphertext, encryptionVersion } = await encryptRefreshToken(tokens.refresh_token);

    const result = await callGoogleServerTx<{ return_to: string | null; calendar_connection_id: string | null }>(
      serviceClient,
      "server_tx_complete_google_oauth",
      {
        p_state_hash: stateHash,
        p_google_subject: googleSubject,
        p_encrypted_refresh_token: ciphertext,
        p_encryption_version: encryptionVersion,
        p_scopes: tokens.scope ? tokens.scope.split(" ") : [],
        p_selected_calendar_id: eligible.id,
        p_selected_calendar_summary: eligible.summary ?? null,
        p_selected_calendar_timezone: eligible.timeZone ?? null,
      },
    );

    return redirectTo(appBaseUrl, result.return_to ?? "/settings/calendar", { google_calendar_connected: "1" });
  } catch (err) {
    if (err instanceof GoogleInvalidGrantError) {
      return redirectTo(appBaseUrl, "/settings/calendar", { google_calendar_error: "invalid_grant" });
    }
    const code2 = (err as { code?: string })?.code;
    if (typeof code2 === "string" && code2.length > 0) {
      return redirectTo(appBaseUrl, "/settings/calendar", { google_calendar_error: code2 });
    }
    console.error("google-calendar-oauth-callback failed", err);
    return redirectTo(appBaseUrl, "/settings/calendar", { google_calendar_error: "internal_error" });
  }
});
