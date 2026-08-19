// verify_jwt=false — cron worker class (see supabase/config.toml +
// EDGE_FUNCTION_AUTH_MATRIX.md). Handler order is safety-critical: the
// worker token MUST be checked before any service-role client is created or
// any DB row is touched (docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md #6;
// EDGE_FUNCTION_AUTH_MATRIX.md "Worker").
//
// WP9: the actual LINE-send loop (outbox claim, atomic quota permit via
// server_tx_reserve_line_quota, provider push call, retry-key/409/429
// handling) that the WP1 stub deliberately left unbuilt
// (docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md #6 "send-notifications").
// Every DB access goes through public.server_tx_* only — private schema
// tables (notification_outbox, line_quota_state, line_quota_reservations,
// line_user_links) are never reached via the Data API `.from()` client, even
// under service_role (docs/design/v6/15_DDL_CONTRACT.md #8; v6 review fix
// P1-2, already the rule the WP1 stub followed for its one RPC call).
//
// LINE_CHANNEL_ACCESS_TOKEN is a real secret that does not exist in this dev
// environment (see MANUAL_SETUP_REQUIRED.md) — referenced by env var name
// only. The push/quota fetch() calls below are the full intended
// implementation; they cannot be live-tested here, matching the same
// documented limitation as WP6/WP7's own provider wire calls.
import { createServiceRoleClient, requireWorkerToken } from "../_shared/auth.ts";
import { withServiceHandler, jsonResponse } from "../_shared/handler.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

// docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md #6 "Worker-only; every
// minute" — batch/lease sizing keeps one invocation well inside a 1-minute
// cadence even if every claimed row needs a real network round trip.
const CLAIM_BATCH_LIMIT = 20;
const LEASE_SECONDS = 90;
const MAX_ATTEMPTS = 5;
const RETRY_DELAY_SECONDS = 60;
// docs/design/v6/ENV_TEMPLATE.md LINE_RETRY_KEY_SAFETY_HOURS=23 and the
// #18 "at least every 15m" quota-refresh cadence are both enforced entirely
// in SQL (server_tx_claim_notification_outbox_batch /
// server_tx_fail_notification_outbox_item /
// server_tx_get_line_quota_refresh_state) — nothing to duplicate here.
const FETCH_TIMEOUT_MS = 10_000;
const LINE_TEXT_MAX_CHARS = 5000;

const LINE_PUSH_URL = "https://api.line.me/v2/bot/message/push";
const LINE_QUOTA_URL = "https://api.line.me/v2/bot/message/quota";
const LINE_QUOTA_CONSUMPTION_URL = "https://api.line.me/v2/bot/message/quota/consumption";

type OutboxItem = {
  user_notification_id?: string;
  type?: string;
  title?: string;
  body?: string;
  dedup_key?: string;
};

type ClaimedNotification = {
  id: string;
  household_id: string;
  recipient_user_id: string;
  type: string;
  payload: { items?: OutboxItem[] } | null;
  dedup_key: string;
  priority: "critical" | "normal" | "reminder";
  attempts: number;
  provider_retry_key: string;
  business_expires_at: string | null;
  quota_reservation_id: string | null;
  lease_token: string;
  line_user_id: string | null;
};

type Outcome = "definitive" | "quota_fallback" | "ambiguous" | "transient";

type RunSummary = {
  claimed: number;
  sent: number;
  quota_fallback: number;
  dead: number;
  requeued: number;
  delivery_unknown: number;
  no_line_link: number;
  quota_refreshed: boolean;
  quota_refresh_skipped_reason: string | null;
};

// Builds one LINE text message per outbox row, folding every bundled item
// (docs/design/v6/06_LINE_INTEGRATION.md #11 "same recipient + same
// scheduled local minute ... one message"; the WP9 bridge trigger in
// 20260819000070 appends bundled items into a single row's payload) into
// one envelope, truncated to LINE's text-message length limit.
function buildBundledText(payload: ClaimedNotification["payload"], type: string): string {
  const items = payload?.items ?? [];
  const blocks = items.length > 0
    ? items.map((item) => {
      const title = item.title ?? "";
      const body = item.body ?? "";
      return body && body !== title ? `${title}\n${body}` : title;
    })
    : [`Family Ops: ${type}`];
  const text = blocks.filter((b) => b.length > 0).join("\n\n");
  if (text.length <= LINE_TEXT_MAX_CHARS) return text;
  return text.slice(0, LINE_TEXT_MAX_CHARS - 1) + "…";
}

async function fetchWithTimeout(url: string, init: RequestInit): Promise<Response> {
  return await fetch(url, { ...init, signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
}

// docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md #18 "LINE quota refresh":
// refresh target monthly limit + total sent usage at least every 15m while
// the LINE outbox exists; unknown/stale data + a failed refresh means
// normal/reminder priority must fall back to in-app rather than guess.
async function maybeRefreshLineQuota(
  serviceClient: SupabaseClient,
  channelAccessToken: string | undefined,
): Promise<{ refreshed: boolean; stale: boolean; skippedReason: string | null }> {
  const { data: state, error } = await serviceClient.rpc("server_tx_get_line_quota_refresh_state");
  if (error) {
    console.error("send-notifications: failed to read quota refresh state", error.message);
    return { refreshed: false, stale: true, skippedReason: "state_read_failed" };
  }
  const stale = Boolean((state as { stale?: boolean })?.stale);
  if (!stale) {
    return { refreshed: false, stale: false, skippedReason: null };
  }
  if (!channelAccessToken) {
    return { refreshed: false, stale: true, skippedReason: "LINE_CHANNEL_ACCESS_TOKEN not configured" };
  }

  try {
    const headers = { Authorization: `Bearer ${channelAccessToken}` };
    const [quotaRes, consumptionRes] = await Promise.all([
      fetchWithTimeout(LINE_QUOTA_URL, { method: "GET", headers }),
      fetchWithTimeout(LINE_QUOTA_CONSUMPTION_URL, { method: "GET", headers }),
    ]);
    if (!quotaRes.ok || !consumptionRes.ok) {
      return { refreshed: false, stale: true, skippedReason: `provider refresh HTTP ${quotaRes.status}/${consumptionRes.status}` };
    }
    const quotaBody = await quotaRes.json() as { type?: string; value?: number };
    const consumptionBody = await consumptionRes.json() as { totalUsage?: number };
    // type='none' means the OA is on an unlimited-by-provider plan; the
    // Family Ops app hard cap (200, enforced entirely inside
    // server_tx_reserve_line_quota) still governs actual admission either
    // way, so a very large placeholder here never itself becomes the
    // effective limit.
    const providerLimit = quotaBody.type === "limited" && typeof quotaBody.value === "number"
      ? quotaBody.value
      : 1_000_000;
    const providerConsumed = typeof consumptionBody.totalUsage === "number" ? consumptionBody.totalUsage : 0;

    const { error: refreshError } = await serviceClient.rpc("server_tx_refresh_line_quota_provider_usage", {
      p_provider_limit: providerLimit,
      p_provider_consumed: providerConsumed,
    });
    if (refreshError) {
      console.error("send-notifications: failed to persist quota refresh", refreshError.message);
      return { refreshed: false, stale: true, skippedReason: "persist_failed" };
    }
    return { refreshed: true, stale: false, skippedReason: null };
  } catch (err) {
    console.error("send-notifications: quota refresh fetch failed", err instanceof Error ? err.message : String(err));
    return { refreshed: false, stale: true, skippedReason: "fetch_failed" };
  }
}

async function failItem(
  serviceClient: SupabaseClient,
  item: ClaimedNotification,
  outcome: Outcome,
  error: string,
): Promise<string> {
  const { data, error: rpcError } = await serviceClient.rpc("server_tx_fail_notification_outbox_item", {
    p_id: item.id,
    p_lease_token: item.lease_token,
    p_error: error.slice(0, 500),
    p_outcome: outcome,
    p_max_attempts: MAX_ATTEMPTS,
    p_retry_delay_seconds: RETRY_DELAY_SECONDS,
  });
  if (rpcError) {
    console.error("send-notifications: fail RPC error", { id: item.id, outcome, message: rpcError.message });
    return "rpc_error";
  }
  return (data as { status?: string })?.status ?? "unknown";
}

async function sendOne(
  serviceClient: SupabaseClient,
  item: ClaimedNotification,
  channelAccessToken: string | undefined,
  quotaStale: boolean,
): Promise<string> {
  if (!item.line_user_id) {
    return await failItem(serviceClient, item, "definitive", "no active LINE link for recipient");
  }

  // #18 "unknown/stale provider data + failed refresh => normal/reminder
  // fallback to in-app". critical still attempts against best-known local
  // state (the reserve RPC's own threshold protects the hard cap either way).
  if (quotaStale && item.priority !== "critical") {
    return await failItem(serviceClient, item, "quota_fallback", "provider quota data stale and refresh unavailable");
  }

  const { data: reservation, error: reserveError } = await serviceClient.rpc("server_tx_reserve_line_quota", {
    p_notification_outbox_id: item.id,
    p_priority: item.priority,
  });
  if (reserveError) {
    console.error("send-notifications: reserve RPC error", { id: item.id, message: reserveError.message });
    return await failItem(serviceClient, item, "ambiguous", `quota reserve RPC failed: ${reserveError.message}`);
  }
  if (!(reservation as { permitted?: boolean })?.permitted) {
    return await failItem(serviceClient, item, "quota_fallback", "monthly LINE quota threshold reached");
  }

  if (!channelAccessToken) {
    // Reservation already exists at this point; releasing it happens inside
    // failItem via the 'ambiguous' path is wrong here (nothing was ever
    // attempted) — this is a config problem, not a delivery uncertainty, so
    // route it the same way quota_fallback does (release + fallback, not
    // dead) since it is entirely recoverable once the secret is configured.
    return await failItem(serviceClient, item, "quota_fallback", "LINE_CHANNEL_ACCESS_TOKEN not configured");
  }

  const text = buildBundledText(item.payload, item.type);
  let response: Response;
  try {
    response = await fetchWithTimeout(LINE_PUSH_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${channelAccessToken}`,
        "Content-Type": "application/json",
        "X-Line-Retry-Key": item.provider_retry_key,
      },
      body: JSON.stringify({
        to: item.line_user_id,
        messages: [{ type: "text", text }],
      }),
    });
  } catch (err) {
    // Network error/timeout: delivery is genuinely unknown.
    const message = err instanceof Error ? err.message : String(err);
    return await failItem(serviceClient, item, "ambiguous", `push fetch failed: ${message}`);
  }

  if (response.ok) {
    const { data, error: completeError } = await serviceClient.rpc("server_tx_complete_notification_outbox_item", {
      p_id: item.id,
      p_lease_token: item.lease_token,
    });
    if (completeError) {
      console.error("send-notifications: complete RPC error", { id: item.id, message: completeError.message });
    }
    return (data as { status?: string })?.status ?? "sent";
  }

  // docs/design/v6/06_LINE_INTEGRATION.md #10A "Result": "409 same retry key
  // => accepted/reconciled + committed" — LINE's own concurrent-request
  // guard for the identical X-Line-Retry-Key means the message was (or is
  // being) sent by an earlier attempt; treat exactly like 2xx.
  if (response.status === 409) {
    const { data, error: completeError } = await serviceClient.rpc("server_tx_complete_notification_outbox_item", {
      p_id: item.id,
      p_lease_token: item.lease_token,
    });
    if (completeError) {
      console.error("send-notifications: complete RPC error (409 reconcile)", { id: item.id, message: completeError.message });
    }
    return (data as { status?: string })?.status ?? "sent";
  }

  if (response.status === 429) {
    // #10A "429": "Do not classify all 429 as monthly quota. refresh
    // provider monthly usage. at/over effective hard limit or explicit
    // monthly-limit error => quota fallback. otherwise transient
    // rate-limit => exponential backoff with same retry key within expiry."
    let bodyText = "";
    try {
      bodyText = await response.text();
    } catch {
      // ignore body-read failure; classify on refreshed usage alone
    }
    const refresh = await maybeRefreshLineQuota(serviceClient, channelAccessToken);
    const looksLikeMonthlyLimit = /monthly/i.test(bodyText);
    if (looksLikeMonthlyLimit || (refresh.refreshed === false && refresh.stale)) {
      // Could not confirm we're still under the cap (or the message itself
      // says so) — treat conservatively as quota-exhausted rather than
      // retry a request that is unlikely to succeed before its own expiry.
      return await failItem(serviceClient, item, "quota_fallback", `429 monthly-limit: ${bodyText.slice(0, 200)}`);
    }
    return await failItem(serviceClient, item, "transient", `429 rate-limited: ${bodyText.slice(0, 200)}`);
  }

  if (response.status >= 500) {
    const bodyText = await response.text().catch(() => "");
    return await failItem(serviceClient, item, "ambiguous", `provider ${response.status}: ${bodyText.slice(0, 200)}`);
  }

  // Any other 4xx (400 malformed, 401/403 bad token, 404 unknown user) is a
  // permanent rejection for this recipient/payload — never retry.
  const bodyText = await response.text().catch(() => "");
  return await failItem(serviceClient, item, "definitive", `provider ${response.status}: ${bodyText.slice(0, 200)}`);
}

Deno.serve(withServiceHandler(async (req: Request) => {
  requireWorkerToken(req); // throws EDGE_WORKER_UNAUTHORIZED before any DB access

  const serviceClient = createServiceRoleClient();
  const channelAccessToken = Deno.env.get("LINE_CHANNEL_ACCESS_TOKEN") ?? undefined;

  const quotaRefresh = await maybeRefreshLineQuota(serviceClient, channelAccessToken);

  const { data: claimedRaw, error: claimError } = await serviceClient.rpc(
    "server_tx_claim_notification_outbox_batch",
    { p_worker_id: crypto.randomUUID(), p_limit: CLAIM_BATCH_LIMIT, p_lease_seconds: LEASE_SECONDS },
  );
  if (claimError) {
    console.error("send-notifications: claim RPC failed", claimError.message);
    return new Response(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "internal error" } }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const claimed = (claimedRaw ?? []) as ClaimedNotification[];

  const summary: RunSummary = {
    claimed: claimed.length,
    sent: 0,
    quota_fallback: 0,
    dead: 0,
    requeued: 0,
    delivery_unknown: 0,
    no_line_link: 0,
    quota_refreshed: quotaRefresh.refreshed,
    quota_refresh_skipped_reason: quotaRefresh.skippedReason,
  };

  for (const item of claimed) {
    if (!item.line_user_id) summary.no_line_link += 1;
    const status = await sendOne(serviceClient, item, channelAccessToken, quotaRefresh.stale);
    switch (status) {
      case "sent":
        summary.sent += 1;
        break;
      case "fallback":
        summary.quota_fallback += 1;
        break;
      case "dead":
        summary.dead += 1;
        break;
      case "queued":
        summary.requeued += 1;
        break;
      case "delivery_unknown":
        summary.delivery_unknown += 1;
        break;
      default:
        console.error("send-notifications: unexpected item outcome", { id: item.id, status });
    }
  }

  return jsonResponse(summary);
}));
