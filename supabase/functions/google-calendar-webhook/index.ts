// verify_jwt=false — external provider class (Google push notifications).
// docs/design/v6/07_GOOGLE_CALENDAR.md #4 "Watch channel" webhook verify.
// verify_jwt=false does NOT mean "trusted": Channel-ID/Resource-ID/
// Channel-Token are checked against the stored watch channel row (via
// server_tx_admit_google_webhook) before anything is enqueued. An
// unknown/stopped/expired/mismatched — but otherwise well-formed — request
// still gets 2xx (no 4xx retry storm for a stale valid-provider channel).
import { createServiceRoleClient } from "../_shared/auth.ts";
import { withServiceHandler } from "../_shared/handler.ts";
import { callGoogleServerTx } from "../_shared/googleCalendar.ts";
import { sha256Hex } from "../_shared/cryptoHelper.ts";

Deno.serve(withServiceHandler(async (req: Request) => {
  const channelId = req.headers.get("X-Goog-Channel-ID");
  const resourceId = req.headers.get("X-Goog-Resource-ID");
  const channelToken = req.headers.get("X-Goog-Channel-Token");
  const resourceState = req.headers.get("X-Goog-Resource-State"); // 'sync' | 'exists' | 'not_exists'

  if (!channelId || !resourceId || !channelToken) {
    // Malformed/incomplete — nothing to admit, but still a 2xx per the "no
    // retry storm" rule; there is no well-formed request to retry into.
    return new Response("ok", { status: 200 });
  }

  const serviceClient = createServiceRoleClient();
  const tokenHash = await sha256Hex(channelToken);

  let admission: { accepted: boolean; calendar_connection_id?: string };
  try {
    admission = await callGoogleServerTx(serviceClient, "server_tx_admit_google_webhook", {
      p_channel_id: channelId,
      p_resource_id: resourceId,
      p_token_hash: tokenHash,
    });
  } catch (err) {
    console.error("google-calendar-webhook: admission check failed", err);
    return new Response("internal error", { status: 500 });
  }

  if (!admission.accepted || !admission.calendar_connection_id) {
    return new Response("ok", { status: 200 });
  }

  // resourceState 'sync' is Google's initial handshake notification when a
  // channel is first created — nothing changed yet, no sync needed.
  if (resourceState === "sync") {
    return new Response("ok", { status: 200 });
  }

  try {
    await callGoogleServerTx(serviceClient, "server_tx_enqueue_google_sync", {
      p_calendar_connection_id: admission.calendar_connection_id,
      p_reason: "webhook",
    });
  } catch (err) {
    console.error("google-calendar-webhook: enqueue failed", err);
    return new Response("internal error", { status: 500 });
  }

  return new Response("ok", { status: 200 });
}));
