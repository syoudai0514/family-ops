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
  GoogleCalendarApiError,
  GoogleInvalidGrantError,
  insertEvent,
  isGoogleCalendarForbiddenError,
  mergePrivateExtendedProperties,
  patchEvent,
  revalidateCalendarEligibilityAfterForbidden,
} from "../_shared/googleCalendar.ts";
import { decryptRefreshToken } from "../_shared/cryptoHelper.ts";
import {
  ProviderMutationFencedError,
  type ProviderMutationAuthorization,
  withProviderMutationFence,
} from "./providerMutationFence.ts";
import { deleteExistingEventWithFence } from "./conditionalDeleteWorkflow.ts";

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

interface ClaimedTargetDeletion {
  id: string;
  household_id: string;
  calendar_connection_id: string;
  projection_key: string;
  provider_event_id: string;
  lease_token: string;
}

function mirrorProperties(event: Record<string, unknown>) {
  const props = event.extendedProperties as { private?: Record<string, string> } | undefined;
  return props?.private ?? {};
}

function requireExpectedGoogleStatus(operation: string, status: number, expected: number[]) {
  if (!expected.includes(status)) throw new GoogleCalendarApiError(operation, status);
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

async function addCanonicalSpecialAssignee(
  client: ReturnType<typeof createServiceRoleClient>, item: ClaimedMirror, event: Record<string, unknown>,
) {
  const props = mirrorProperties(event); const taskId = props.familyOpsTaskInstanceId;
  if (!taskId || props.familyOpsKind !== 'special') return event;
  const { data: task } = await client.from('task_instances').select('planned_assignee_id').eq('household_id', item.household_id).eq('id', taskId).maybeSingle();
  const { data: member } = task?.planned_assignee_id
    ? await client.from('household_members').select('family_role').eq('household_id', item.household_id).eq('user_id', task.planned_assignee_id).maybeSingle()
    : { data: null };
  const token = member?.family_role === 'papa' ? 'P' : member?.family_role === 'mama' ? 'M' : '未';
  return { ...event, summary: `${String(event.summary ?? '')} [${token}]` };
}

async function authorizeMirrorMutation(
  client: ReturnType<typeof createServiceRoleClient>,
  item: ClaimedMirror,
  providerEventId: string,
): Promise<ProviderMutationAuthorization> {
  return await callGoogleServerTx<ProviderMutationAuthorization>(
    client,
    "server_tx_authorize_family_ops_calendar_mirror",
    {
      p_household_id: item.household_id,
      p_projection_key: item.projection_key,
      p_lease_token: item.lease_token,
      p_calendar_connection_id: item.calendar_connection_id,
      p_provider_event_id: providerEventId,
    },
  );
}

async function authorizeTargetDeletionMutation(
  client: ReturnType<typeof createServiceRoleClient>,
  item: ClaimedTargetDeletion,
): Promise<ProviderMutationAuthorization> {
  return await callGoogleServerTx<ProviderMutationAuthorization>(
    client,
    "server_tx_authorize_family_ops_calendar_target_deletion",
    { p_id: item.id, p_lease_token: item.lease_token },
  );
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
  // Calendar target changes are also outbox work. Delete the old mirror via
  // its stable provider id before handling ordinary upserts on the new target.
  const targetDeletion = await callGoogleServerTx<ClaimedTargetDeletion | null>(serviceClient, "server_tx_claim_family_ops_calendar_target_deletion", {
    p_worker_id: WORKER_ID,
    p_lease_seconds: 120,
  });
  if (targetDeletion) {
    let cleanupAccessToken: string | null = null;
    let cleanupCalendarId: string | null = null;
    try {
      const { accessToken, externalCalendarId } = await getAccessTokenForConnection(
        serviceClient, targetDeletion.calendar_connection_id, decryptRefreshToken,
      );
      cleanupAccessToken = accessToken;
      cleanupCalendarId = externalCalendarId;
      const status = await deleteExistingEventWithFence({
        readEvent: () => getEvent({
          accessToken,
          calendarId: externalCalendarId,
          eventId: targetDeletion.provider_event_id,
        }),
        authorize: () => authorizeTargetDeletionMutation(serviceClient, targetDeletion),
        deleteWithEtag: (etag) => deleteEvent({
          accessToken,
          calendarId: externalCalendarId,
          eventId: targetDeletion.provider_event_id,
          ifMatchEtag: etag,
        }),
      });
      requireExpectedGoogleStatus("target deletion", status, [200, 204, 404, 410]);
      await callGoogleServerTx(serviceClient, "server_tx_complete_family_ops_calendar_target_deletion", {
        p_id: targetDeletion.id, p_lease_token: targetDeletion.lease_token,
      });
      return new Response(JSON.stringify({ processed: 1, target_cleanup: targetDeletion.projection_key }), { status: 200, headers: { "Content-Type": "application/json" } });
    } catch (error) {
      if (error instanceof ProviderMutationFencedError) {
        // Stale/superseded work is expected concurrency, not a provider error.
        // Most importantly, withProviderMutationFence did not invoke DELETE.
        return new Response(JSON.stringify({
          processed: 0,
          target_cleanup: targetDeletion.projection_key,
          superseded: true,
          reason: error.reason,
        }), { status: 200, headers: { "Content-Type": "application/json" } });
      }
      if (isGoogleCalendarForbiddenError(error) && cleanupAccessToken && cleanupCalendarId) {
        await revalidateCalendarEligibilityAfterForbidden(serviceClient, {
          calendarConnectionId: targetDeletion.calendar_connection_id,
          externalCalendarId: cleanupCalendarId,
          accessToken: cleanupAccessToken,
          reason: "403 during stale target cleanup",
        });
      }
      await callGoogleServerTx(serviceClient, "server_tx_fail_family_ops_calendar_target_deletion", {
        p_id: targetDeletion.id, p_lease_token: targetDeletion.lease_token,
        p_error: String(error instanceof Error ? error.message : error),
      }).catch(() => undefined);
      console.error("family calendar target cleanup failed", { projectionKey: targetDeletion.projection_key, error });
      return new Response(JSON.stringify({ processed: 0, target_cleanup: targetDeletion.projection_key, error: "mirror_failed" }), { status: 200, headers: { "Content-Type": "application/json" } });
    }
  }

  const item = await callGoogleServerTx<ClaimedMirror | null>(serviceClient, "server_tx_claim_family_ops_calendar_mirror", {
    p_worker_id: WORKER_ID,
    p_lease_seconds: 120,
  });
  if (!item) {
    return new Response(JSON.stringify({ processed: 0 }), { status: 200, headers: { "Content-Type": "application/json" } });
  }

  let accessToken: string | null = null;
  let externalCalendarId: string | null = null;
  try {
    const connection = await getAccessTokenForConnection(
      serviceClient,
      item.calendar_connection_id,
      decryptRefreshToken,
    );
    const providerAccessToken = connection.accessToken;
    const providerCalendarId = connection.externalCalendarId;
    accessToken = providerAccessToken;
    externalCalendarId = providerCalendarId;

    if (item.action === "delete") {
      const targetId = item.provider_event_id;
      if (targetId) {
        const status = await deleteExistingEventWithFence({
          readEvent: () => getEvent({
            accessToken: providerAccessToken,
            calendarId: providerCalendarId,
            eventId: targetId,
          }),
          authorize: () => authorizeMirrorMutation(serviceClient, item, targetId),
          deleteWithEtag: (etag) => deleteEvent({
            accessToken: providerAccessToken,
            calendarId: providerCalendarId,
            eventId: targetId,
            ifMatchEtag: etag,
          }),
        });
        requireExpectedGoogleStatus("deleteEvent", status, [200, 204, 404, 410]);
      }
      await complete(serviceClient, item, targetId, null, true);
    } else {
      if (!item.event) throw new Error("claimed mirror omitted event payload");
      const targetId = item.provider_event_id ?? item.deterministic_event_id;
      const desired = eventPayloadWithStableIdentity({ ...(await addCanonicalSpecialAssignee(serviceClient, item, item.event)), id: targetId });
      const existing = await getEvent({ accessToken: providerAccessToken, calendarId: providerCalendarId, eventId: targetId });
      let etag: string | null = null;

      if (existing.status === 404) {
        const inserted = await withProviderMutationFence(
          () => authorizeMirrorMutation(serviceClient, item, targetId),
          () => insertEvent({ accessToken: providerAccessToken, calendarId: providerCalendarId, body: desired }),
        );
        if (inserted.status === 409) {
          // A response may have been lost after create. Verify the durable
          // projection marker on the deterministic id; never search by title.
          const reconciled = await getEvent({ accessToken: providerAccessToken, calendarId: providerCalendarId, eventId: targetId });
          if (reconciled.status !== 200 || mirrorProperties(reconciled.body ?? {}).familyOpsProjectionKey !== item.projection_key) {
            throw new Error("provider id collision for Family Ops mirror");
          }
          etag = reconciled.etag;
        } else if (inserted.status === 200 || inserted.status === 201) {
          etag = typeof inserted.body?.etag === "string" ? inserted.body.etag : null;
        } else {
          requireExpectedGoogleStatus("insertEvent", inserted.status, [200, 201]);
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
        const patched = await withProviderMutationFence(
          () => authorizeMirrorMutation(serviceClient, item, targetId),
          () => patchEvent({
            accessToken: providerAccessToken,
            calendarId: providerCalendarId,
            eventId: targetId,
            body: desiredForPatch,
            ifMatchEtag: existing.etag ?? "",
          }),
        );
        if (patched.status === 412) {
          const latest = await getEvent({ accessToken: providerAccessToken, calendarId: providerCalendarId, eventId: targetId });
          const latestEtag = latest.etag;
          if (latest.status !== 200 || !latestEtag) throw new Error("calendar event changed and could not be reread");
          const retry = await withProviderMutationFence(
            () => authorizeMirrorMutation(serviceClient, item, targetId),
            () => patchEvent({
              accessToken: providerAccessToken,
              calendarId: providerCalendarId,
              eventId: targetId,
              body: {
                ...desiredForPatch,
                extendedProperties: {
                  private: mergePrivateExtendedProperties(mirrorProperties(latest.body ?? {}), mirrorProperties(desired)),
                },
              },
              ifMatchEtag: latestEtag,
            }),
          );
          requireExpectedGoogleStatus("patchEvent retry", retry.status, [200]);
          etag = typeof retry.body?.etag === "string" ? retry.body.etag : latestEtag;
        } else if (patched.status === 200) {
          etag = typeof patched.body?.etag === "string" ? patched.body.etag : existing.etag;
        } else {
          requireExpectedGoogleStatus("patchEvent", patched.status, [200]);
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
    if (error instanceof ProviderMutationFencedError) {
      // Another lease owner or a Family Event transfer won the race. Do not
      // fail/requeue the row from this stale worker and never call the provider.
      return new Response(JSON.stringify({
        processed: 0,
        projection_key: item.projection_key,
        superseded: true,
        reason: error.reason,
      }), { status: 200, headers: { "Content-Type": "application/json" } });
    }
    if (error instanceof GoogleInvalidGrantError) {
      await callGoogleServerTx(serviceClient, "server_tx_mark_google_reauth_required", {
        p_calendar_connection_id: item.calendar_connection_id,
        p_reason: "invalid_grant during Family Ops mirror write",
      }).catch(() => undefined);
    } else if (isGoogleCalendarForbiddenError(error) && accessToken && externalCalendarId) {
      await revalidateCalendarEligibilityAfterForbidden(serviceClient, {
        calendarConnectionId: item.calendar_connection_id,
        externalCalendarId,
        accessToken,
        reason: "403 during Family Ops mirror write",
      });
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