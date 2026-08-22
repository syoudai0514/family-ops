// verify_jwt=false — cron worker (X-Family-Ops-Worker-Token).
// The worker applies the private Family Ops outbox to Google Calendar. Local
// mutations have already committed before this code runs, so provider errors
// become retryable outbox failures and never roll back the household record.
import { createServiceRoleClient, requireWorkerToken } from "../_shared/auth.ts";
import { withServiceHandler } from "../_shared/handler.ts";
import {
  callGoogleServerTx,
  deleteEvent,
  getAccessTokenForConnection,
  getEvent,
  GoogleInvalidGrantError,
  insertEvent,
  mergePrivateExtendedProperties,
  patchEvent,
} from "../_shared/googleCalendar.ts";
import { decryptRefreshToken } from "../_shared/cryptoHelper.ts";

const WORKER_ID = `process-family-ops-calendar-outbox:${crypto.randomUUID()}`;

interface ClaimedMirror {
  household_id: string;
  projection_key: string;
  calendar_connection_id: string;
  lease_token: string;
  action: "upsert" | "delete";
  provider_event_id: string | null;
  deterministic_event_id: string;
  event?: Record<string, unknown>;
}

function mirrorProperties(event: Record<string, unknown>) {
  const props = event.extendedProperties as { private?: Record<string, string> } | undefined;
  return props?.private ?? {};
}

function eventPayloadWithStableIdentity(event: Record<string, unknown>) {
  const extended = event.extendedProperties as { private?: Record<string, string> } | undefined;
  return {
    ...event,
    extendedProperties: {
      private: mergePrivateExtendedProperties(extended?.private, {
        familyOpsMirror: "true",
        familyOpsProjectionKey: String(extended?.private?.familyOpsProjectionKey ?? ""),
        familyOpsKind: String(extended?.private?.familyOpsKind ?? ""),
        familyOpsTaskInstanceId: String(extended?.private?.familyOpsTaskInstanceId ?? ""),
      }),
    },
  };
}

async function complete(
  client: ReturnType<typeof createServiceRoleClient>,
  item: ClaimedMirror,
  providerEventId: string | null,
  etag: string | null,
  deleted: boolean,
) {
  await callGoogleServerTx(client, "server_tx_complete_family_ops_calendar_mirror", {
    p_household_id: item.household_id,
    p_projection_key: item.projection_key,
    p_lease_token: item.lease_token,
    p_provider_event_id: providerEventId,
    p_provider_etag: etag,
    p_deleted: deleted,
  });
}

Deno.serve(withServiceHandler(async (req: Request) => {
  requireWorkerToken(req);
  const serviceClient = createServiceRoleClient();
  const item = await callGoogleServerTx<ClaimedMirror | null>(serviceClient, "server_tx_claim_family_ops_calendar_mirror", {
    p_worker_id: WORKER_ID,
    p_lease_seconds: 120,
  });
  if (!item) {
    return new Response(JSON.stringify({ processed: 0 }), { status: 200, headers: { "Content-Type": "application/json" } });
  }

  try {
    const { accessToken, externalCalendarId } = await getAccessTokenForConnection(
      serviceClient,
      item.calendar_connection_id,
      decryptRefreshToken,
    );

    if (item.action === "delete") {
      const targetId = item.provider_event_id;
      if (targetId) {
        const existing = await getEvent({ accessToken, calendarId: externalCalendarId, eventId: targetId });
        if (existing.status === 200) {
          let status = await deleteEvent({ accessToken, calendarId: externalCalendarId, eventId: targetId, ifMatchEtag: existing.etag });
          if (status === 412) {
            const latest = await getEvent({ accessToken, calendarId: externalCalendarId, eventId: targetId });
            status = latest.status === 200
              ? await deleteEvent({ accessToken, calendarId: externalCalendarId, eventId: targetId, ifMatchEtag: latest.etag })
              : latest.status;
          }
          if (![200, 204, 404, 410].includes(status)) {
            throw new Error(`deleteEvent returned ${status}`);
          }
        }
      }
      await complete(serviceClient, item, targetId, null, true);
    } else {
      if (!item.event) throw new Error("claimed mirror omitted event payload");
      const targetId = item.provider_event_id ?? item.deterministic_event_id;
      const desired = eventPayloadWithStableIdentity({ ...item.event, id: targetId });
      const existing = await getEvent({ accessToken, calendarId: externalCalendarId, eventId: targetId });
      let etag: string | null = null;

      if (existing.status === 404) {
        const inserted = await insertEvent({ accessToken, calendarId: externalCalendarId, body: desired });
        if (inserted.status === 409) {
          // A response may have been lost after create. Verify the durable
          // projection marker on the deterministic id; never search by title.
          const reconciled = await getEvent({ accessToken, calendarId: externalCalendarId, eventId: targetId });
          if (reconciled.status !== 200 || mirrorProperties(reconciled.body ?? {}).familyOpsProjectionKey !== item.projection_key) {
            throw new Error("provider id collision for Family Ops mirror");
          }
          etag = reconciled.etag;
        } else if (inserted.status === 200 || inserted.status === 201) {
          etag = typeof inserted.body?.etag === "string" ? inserted.body.etag : null;
        } else {
          throw new Error(`insertEvent returned ${inserted.status}`);
        }
      } else {
        if (!item.provider_event_id && mirrorProperties(existing.body ?? {}).familyOpsProjectionKey !== item.projection_key) {
          throw new Error("provider id collision for Family Ops mirror");
        }
        const desiredForPatch = {
          ...desired,
          extendedProperties: {
            private: mergePrivateExtendedProperties(
              mirrorProperties(existing.body ?? {}),
              mirrorProperties(desired),
            ),
          },
        };
        const patched = await patchEvent({
          accessToken,
          calendarId: externalCalendarId,
          eventId: targetId,
          body: desiredForPatch,
          ifMatchEtag: existing.etag ?? "",
        });
        if (patched.status === 412) {
          const latest = await getEvent({ accessToken, calendarId: externalCalendarId, eventId: targetId });
          if (latest.status !== 200 || !latest.etag) throw new Error("calendar event changed and could not be reread");
          const retry = await patchEvent({
            accessToken, calendarId: externalCalendarId, eventId: targetId,
            body: {
              ...desiredForPatch,
              extendedProperties: {
                private: mergePrivateExtendedProperties(mirrorProperties(latest.body ?? {}), mirrorProperties(desired)),
              },
            },
            ifMatchEtag: latest.etag,
          });
          if (retry.status !== 200) throw new Error(`patchEvent retry returned ${retry.status}`);
          etag = typeof retry.body?.etag === "string" ? retry.body.etag : latest.etag;
        } else if (patched.status === 200) {
          etag = typeof patched.body?.etag === "string" ? patched.body.etag : existing.etag;
        } else {
          throw new Error(`patchEvent returned ${patched.status}`);
        }
      }
      await complete(serviceClient, item, targetId, etag, false);
      // Canonical inbound cache is refreshed independently. Its projection
      // trigger recognises this event via provider_event_id and suppresses it
      // from the Family Ops UI mirror, without title/date dedupe.
      await callGoogleServerTx(serviceClient, "server_tx_enqueue_google_sync", {
        p_calendar_connection_id: item.calendar_connection_id,
        p_reason: "family_ops_mirror_write",
      });
    }
    return new Response(JSON.stringify({ processed: 1, projection_key: item.projection_key }), {
      status: 200, headers: { "Content-Type": "application/json" },
    });
  } catch (error) {
    if (error instanceof GoogleInvalidGrantError) {
      await callGoogleServerTx(serviceClient, "server_tx_mark_google_reauth_required", {
        p_calendar_connection_id: item.calendar_connection_id,
        p_reason: "invalid_grant during Family Ops mirror write",
      }).catch(() => undefined);
    }
    await callGoogleServerTx(serviceClient, "server_tx_fail_family_ops_calendar_mirror", {
      p_household_id: item.household_id,
      p_projection_key: item.projection_key,
      p_lease_token: item.lease_token,
      p_error: String(error instanceof Error ? error.message : error),
    }).catch(() => undefined);
    console.error("process-family-ops-calendar-outbox failed", { projectionKey: item.projection_key, error });
    return new Response(JSON.stringify({ processed: 0, projection_key: item.projection_key, error: "mirror_failed" }), {
      status: 200, headers: { "Content-Type": "application/json" },
    });
  }
}));
