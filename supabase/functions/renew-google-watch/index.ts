// verify_jwt=false — cron worker (X-Family-Ops-Worker-Token), per
// EDGE_FUNCTION_AUTH_MATRIX.md's "Worker" class: the token is checked
// *before* any service-role client is created or DB is touched.
// docs/design/v6/07_GOOGLE_CALENDAR.md #4-#5 "Watch channel" / "Renewal".
import { createServiceRoleClient, requireWorkerToken } from "../_shared/auth.ts";
import { withServiceHandler } from "../_shared/handler.ts";
import {
  callGoogleServerTx,
  createWatchChannel,
  getAccessTokenForConnection,
  isGoogleCalendarForbiddenError,
  GoogleInvalidGrantError,
  revalidateCalendarEligibilityAfterForbidden,
  stopWatchChannel,
} from "../_shared/googleCalendar.ts";
import { decryptRefreshToken, randomHex, sha256Hex } from "../_shared/cryptoHelper.ts";

Deno.serve(withServiceHandler(async (req: Request) => {
  requireWorkerToken(req);

  const webhookUrl = Deno.env.get("GOOGLE_CALENDAR_WEBHOOK_URL");
  if (!webhookUrl) {
    throw new Error("GOOGLE_CALENDAR_WEBHOOK_URL not configured");
  }

  const serviceClient = createServiceRoleClient();
  let created = 0;
  let stopped = 0;
  let reauthMarked = 0;

  // Step 1-4: create/renew. Covers both "no channel yet" (brand new
  // connection) and "existing channel expiring soon" in one query (#5).
  const needingWatch = await callGoogleServerTx<{ calendar_connection_id: string }[]>(
    serviceClient,
    "server_tx_list_calendar_connections_needing_watch",
    { p_lead_minutes: 60 },
  );

  for (const conn of needingWatch) {
    let accessToken: string | null = null;
    let externalCalendarId: string | null = null;
    try {
      const connection = await getAccessTokenForConnection(
        serviceClient,
        conn.calendar_connection_id,
        decryptRefreshToken,
      );
      accessToken = connection.accessToken;
      externalCalendarId = connection.externalCalendarId;

      const channelId = crypto.randomUUID();
      const rawToken = randomHex(32);
      const { resourceId, expiration } = await createWatchChannel({
        accessToken,
        calendarId: externalCalendarId,
        channelId,
        token: rawToken,
        webhookUrl,
      });

      await callGoogleServerTx(serviceClient, "server_tx_register_google_watch_channel", {
        p_calendar_connection_id: conn.calendar_connection_id,
        p_channel_id: channelId,
        p_resource_id: resourceId,
        p_token_hash: await sha256Hex(rawToken),
        p_expires_at: new Date(expiration).toISOString(),
      });
      created++;
    } catch (err) {
      if (err instanceof GoogleInvalidGrantError) {
        await callGoogleServerTx(serviceClient, "server_tx_mark_google_reauth_required", {
          p_calendar_connection_id: conn.calendar_connection_id,
          p_reason: "invalid_grant during watch renewal",
        });
        reauthMarked++;
        continue;
      }
      if (isGoogleCalendarForbiddenError(err) && accessToken && externalCalendarId) {
        await revalidateCalendarEligibilityAfterForbidden(serviceClient, {
          calendarConnectionId: conn.calendar_connection_id,
          externalCalendarId,
          accessToken,
          reason: "403 during Google watch create or renewal",
        });
      }
      console.error("renew-google-watch: failed to create/renew watch", { calendarConnectionId: conn.calendar_connection_id, err });
    }
  }

  // Step 5-6: stop channels whose overlap window has clearly closed.
  const retiring = await callGoogleServerTx<{ channel_id: string; resource_id: string; calendar_connection_id: string }[]>(
    serviceClient,
    "server_tx_list_retiring_google_watch_channels",
    { p_older_than_minutes: 30 },
  );

  for (const ch of retiring) {
    let accessToken: string | null = null;
    let externalCalendarId: string | null = null;
    try {
      const connection = await getAccessTokenForConnection(serviceClient, ch.calendar_connection_id, decryptRefreshToken);
      accessToken = connection.accessToken;
      externalCalendarId = connection.externalCalendarId;
      await stopWatchChannel({ accessToken, channelId: ch.channel_id, resourceId: ch.resource_id });
      await callGoogleServerTx(serviceClient, "server_tx_mark_google_watch_stopped", { p_channel_id: ch.channel_id });
      stopped++;
    } catch (err) {
      if (err instanceof GoogleInvalidGrantError) {
        await callGoogleServerTx(serviceClient, "server_tx_mark_google_reauth_required", {
          p_calendar_connection_id: ch.calendar_connection_id,
          p_reason: "invalid_grant while stopping a retiring watch channel",
        });
        continue;
      }
      if (isGoogleCalendarForbiddenError(err) && accessToken && externalCalendarId) {
        await revalidateCalendarEligibilityAfterForbidden(serviceClient, {
          calendarConnectionId: ch.calendar_connection_id,
          externalCalendarId,
          accessToken,
          reason: "403 while stopping a retiring Google watch channel",
        });
      }
      console.error("renew-google-watch: failed to stop retiring channel", { channelId: ch.channel_id, err });
    }
  }

  return new Response(JSON.stringify({ created, stopped, reauth_marked: reauthMarked }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}));
