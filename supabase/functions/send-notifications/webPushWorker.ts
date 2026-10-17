// Delivers queued PWA pushes (private.web_push_outbox) on the same per-minute
// cron as LINE. Each row is one device; failures retry with backoff in SQL.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { sendWebPush, type VapidConfig } from "../_shared/webPush.ts";

export type ClaimedPush = {
  outbox_id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
  title: string;
  body: string;
  url: string;
  tag: string | null;
  expires_at: string;
};

export type PushRunSummary = { claimed: number; sent: number; retry: number; gone: number; dead: number };

export async function processWebPushOutbox(
  client: SupabaseClient,
  vapid: VapidConfig,
  send: typeof sendWebPush = sendWebPush,
  now: () => number = Date.now,
): Promise<PushRunSummary> {
  const summary: PushRunSummary = { claimed: 0, sent: 0, retry: 0, gone: 0, dead: 0 };
  const { data, error } = await client.rpc("server_tx_claim_web_push_batch", { p_limit: 50, p_lease_seconds: 60 });
  if (error) {
    console.error("send-notifications: web push claim failed", error.message);
    return summary;
  }
  const claimed = (data ?? []) as ClaimedPush[];
  summary.claimed = claimed.length;
  for (const item of claimed) {
    // A reminder that arrives after its event is noise; let the push service drop it.
    const ttl = Math.max(60, Math.floor((new Date(item.expires_at).getTime() - now()) / 1000));
    const result = await send(
      { endpoint: item.endpoint, p256dh: item.p256dh, auth: item.auth },
      { title: item.title, body: item.body, url: item.url, tag: item.tag },
      vapid,
      ttl,
    );
    summary[result.outcome] += 1;
    const { error: completeError } = await client.rpc("server_tx_complete_web_push", {
      p_outbox_id: item.outbox_id,
      p_outcome: result.outcome,
      p_error: result.error ?? (result.status ? String(result.status) : null),
    });
    if (completeError) console.error("send-notifications: web push complete failed", completeError.message);
  }
  return summary;
}
