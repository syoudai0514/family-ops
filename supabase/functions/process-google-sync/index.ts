// verify_jwt=false — cron worker (X-Family-Ops-Worker-Token). The workhorse
// of WP7C/D/E: claims one queued sync job, runs the canonical
// syncToken-based sync (staging -> atomic commit, with 410 recovery), then
// rebuilds the rolling occurrence projection + busy members, and reports
// the outcome back to the lease.
// docs/design/v6/07_GOOGLE_CALENDAR.md #6 "Canonical incremental sync", #8
// "Rolling occurrence projection".
import { createServiceRoleClient, requireWorkerToken } from "../_shared/auth.ts";
import { withServiceHandler } from "../_shared/handler.ts";
import {
  callGoogleServerTx,
  getAccessTokenForConnection,
  GoogleInvalidGrantError,
  isGoogleCalendarForbiddenError,
  listCanonicalEventsPage,
  listProjectionEventsPage,
  projectionWindow,
  revalidateCalendarEligibilityAfterForbidden,
} from "../_shared/googleCalendar.ts";
import { decryptRefreshToken } from "../_shared/cryptoHelper.ts";

const LEASE_SECONDS = 170; // comfortably under Edge Functions' request timeout.
const WORKER_ID = `process-google-sync:${crypto.randomUUID()}`;

interface ClaimedJob {
  job_id: string;
  lease_token: string;
  calendar_connection_id: string;
}

// Stages every page of a canonical events.list run, restarting once (fresh
// sync_run_id, full resync) on a 410 Gone. #6 step 4: a page 2+ failure
// leaves live cache/token state untouched because staging is never
// committed until every page of *this* run succeeded.
async function runCanonicalSync(opts: {
  serviceClient: ReturnType<typeof createServiceRoleClient>;
  accessToken: string;
  calendarId: string;
  calendarConnectionId: string;
  storedSyncToken: string | null;
}): Promise<{ syncRunId: string; nextSyncToken: string; isFullResync: boolean }> {
  let syncToken = opts.storedSyncToken;
  let isFullResync = !syncToken;
  let attempted410Recovery = false;

  for (;;) {
    const syncRunId = crypto.randomUUID();
    let pageToken: string | null = null;
    let nextSyncToken: string | undefined;

    try {
      do {
        const page = await listCanonicalEventsPage({
          accessToken: opts.accessToken,
          calendarId: opts.calendarId,
          syncToken: isFullResync ? null : syncToken,
          pageToken,
        });
        await callGoogleServerTx(opts.serviceClient, "server_tx_stage_google_events", {
          p_calendar_connection_id: opts.calendarConnectionId,
          p_sync_run_id: syncRunId,
          p_events: page.items,
        });
        pageToken = page.nextPageToken ?? null;
        if (page.nextSyncToken) nextSyncToken = page.nextSyncToken;
      } while (pageToken);

      if (!nextSyncToken) {
        throw new Error("google events.list final page did not include nextSyncToken");
      }
      return { syncRunId, nextSyncToken, isFullResync };
    } catch (err) {
      const status = (err as { status?: number })?.status;
      if (status === 410 && !attempted410Recovery) {
        attempted410Recovery = true;
        await callGoogleServerTx(opts.serviceClient, "server_tx_invalidate_google_sync_token", {
          p_calendar_connection_id: opts.calendarConnectionId,
          p_reason: "410 Gone",
        });
        syncToken = null;
        isFullResync = true;
        continue;
      }
      throw err;
    }
  }
}

async function rebuildProjection(opts: {
  serviceClient: ReturnType<typeof createServiceRoleClient>;
  accessToken: string;
  calendarId: string;
  calendarConnectionId: string;
}): Promise<void> {
  const window = projectionWindow();
  const instances: Record<string, unknown>[] = [];
  let pageToken: string | null = null;
  do {
    const page = await listProjectionEventsPage({
      accessToken: opts.accessToken,
      calendarId: opts.calendarId,
      timeMinRfc3339: window.start,
      timeMaxRfc3339: window.end,
      pageToken,
    });
    instances.push(...page.items);
    pageToken = page.nextPageToken ?? null;
  } while (pageToken);

  await callGoogleServerTx(opts.serviceClient, "server_tx_rebuild_google_occurrence_projection", {
    p_calendar_connection_id: opts.calendarConnectionId,
    p_window_start: window.startDate,
    p_window_end: window.endDate,
    p_instances: instances,
  });
}

Deno.serve(withServiceHandler(async (req: Request) => {
  requireWorkerToken(req);

  const serviceClient = createServiceRoleClient();

  // Best-effort housekeeping; never blocks the main claim/process path.
  await callGoogleServerTx(serviceClient, "server_tx_cleanup_abandoned_google_staging", { p_ttl_hours: 24 }).catch(
    (err) => console.error("process-google-sync: staging cleanup failed", err),
  );

  const claimed = await callGoogleServerTx<ClaimedJob | null>(serviceClient, "server_tx_claim_google_sync_job", {
    p_worker_id: WORKER_ID,
    p_lease_seconds: LEASE_SECONDS,
  });

  if (!claimed) {
    return new Response(JSON.stringify({ processed: 0 }), { status: 200, headers: { "Content-Type": "application/json" } });
  }

  let accessToken: string | null = null;
  let externalCalendarId: string | null = null;
  try {
    const connection = await getAccessTokenForConnection(
      serviceClient,
      claimed.calendar_connection_id,
      decryptRefreshToken,
    );
    accessToken = connection.accessToken;
    externalCalendarId = connection.externalCalendarId;

    const context = await callGoogleServerTx<{ next_sync_token: string | null }>(
      serviceClient,
      "server_tx_get_google_sync_context",
      { p_calendar_connection_id: claimed.calendar_connection_id },
    );

    const { syncRunId, nextSyncToken, isFullResync } = await runCanonicalSync({
      serviceClient,
      accessToken,
      calendarId: externalCalendarId,
      calendarConnectionId: claimed.calendar_connection_id,
      storedSyncToken: context.next_sync_token,
    });

    await callGoogleServerTx(serviceClient, "server_tx_commit_google_sync", {
      p_calendar_connection_id: claimed.calendar_connection_id,
      p_sync_run_id: syncRunId,
      p_next_sync_token: nextSyncToken,
      p_is_full_resync: isFullResync,
    });

    await rebuildProjection({
      serviceClient,
      accessToken,
      calendarId: externalCalendarId,
      calendarConnectionId: claimed.calendar_connection_id,
    });

    await callGoogleServerTx(serviceClient, "server_tx_complete_google_sync_job", {
      p_job_id: claimed.job_id,
      p_lease_token: claimed.lease_token,
      p_success: true,
      p_error: null,
    });

    return new Response(JSON.stringify({ processed: 1, job_id: claimed.job_id }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    if (err instanceof GoogleInvalidGrantError) {
      await callGoogleServerTx(serviceClient, "server_tx_mark_google_reauth_required", {
        p_calendar_connection_id: claimed.calendar_connection_id,
        p_reason: "invalid_grant during sync",
      }).catch((e) => console.error("process-google-sync: failed to mark reauth_required", e));
    } else if (isGoogleCalendarForbiddenError(err) && accessToken && externalCalendarId) {
      await revalidateCalendarEligibilityAfterForbidden(serviceClient, {
        calendarConnectionId: claimed.calendar_connection_id,
        externalCalendarId,
        accessToken,
        reason: "403 during Google sync",
      });
    }
    console.error("process-google-sync: job failed", { jobId: claimed.job_id, err });
    await callGoogleServerTx(serviceClient, "server_tx_complete_google_sync_job", {
      p_job_id: claimed.job_id,
      p_lease_token: claimed.lease_token,
      p_success: false,
      p_error: String(err instanceof Error ? err.message : err),
    }).catch((e) => console.error("process-google-sync: failed to report job failure", e));

    return new Response(JSON.stringify({ processed: 0, job_id: claimed.job_id, error: "sync_failed" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }
}));
