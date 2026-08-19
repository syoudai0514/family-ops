// verify_jwt=true. docs/design/v6/07_GOOGLE_CALENDAR.md #2A "Start".
// Returns an authorization_url rather than issuing a 302 itself: the caller
// is an authenticated in-app fetch (Authorization bearer header), and a
// top-level browser navigation to Google cannot carry that header, so the
// SPA is expected to do `location.href = authorization_url` itself.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { readJsonBody } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import { handlePreflight } from "../_shared/cors.ts";
import { jsonResponse } from "../_shared/handler.ts";
import { buildAuthorizationUrl, callGoogleServerTx, toGoogleErrorResponse } from "../_shared/googleCalendar.ts";
import { randomHex, sha256Hex } from "../_shared/cryptoHelper.ts";

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  try {
    const actorId = await requireUserActor(req);
    const body = await readJsonBody(req).catch(() => ({} as Record<string, unknown>));
    const returnTo = body["return_to"];
    if (returnTo !== undefined && returnTo !== null && typeof returnTo !== "string") {
      throw new FamilyOpsError("INVALID_INPUT", "return_to must be a string", 400);
    }

    const clientId = Deno.env.get("GOOGLE_CALENDAR_CLIENT_ID");
    const redirectUri = Deno.env.get("GOOGLE_CALENDAR_REDIRECT_URI");
    if (!clientId || !redirectUri) {
      throw new Error("GOOGLE_CALENDAR_CLIENT_ID / GOOGLE_CALENDAR_REDIRECT_URI not configured");
    }

    const rawState = randomHex(32); // 256-bit, per #2A step 2.
    const stateHash = await sha256Hex(rawState);

    const serviceClient = createServiceRoleClient();
    const result = await callGoogleServerTx<{ expires_at: string }>(
      serviceClient,
      "server_tx_start_google_oauth",
      {
        p_actor_id: actorId,
        p_state_hash: stateHash,
        p_return_to: typeof returnTo === "string" ? returnTo : null,
      },
    );

    const authorizationUrl = buildAuthorizationUrl({ clientId, redirectUri, state: rawState });
    return jsonResponse({ authorization_url: authorizationUrl, expires_at: result.expires_at });
  } catch (err) {
    return toGoogleErrorResponse(err);
  }
});
