// Web Push subscription actions, called from update-notification-preferences.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { createServiceRoleClient } from "./auth.ts";
import { jsonResponse } from "./handler.ts";
import { callServerTx } from "./rpc.ts";
import { FamilyOpsError } from "./errors.ts";
import { isAllowedPushEndpoint, resolveVapidConfig, sendWebPush } from "./webPush.ts";

type StoredSubscription = { subscription_id: string; endpoint: string; p256dh: string; auth: string; active: boolean } | null;

function requireEndpoint(body: Record<string, unknown>): string {
  const endpoint = body["endpoint"];
  if (typeof endpoint !== "string" || !isAllowedPushEndpoint(endpoint)) {
    throw new FamilyOpsError("INVALID_INPUT", "endpoint is not a supported push service", 400);
  }
  return endpoint;
}

/**
 * Push on/off for the caller's own device. Lives inside update-notification-preferences
 * because the Supabase Free plan caps the project at 100 Edge Functions.
 * Actions: config (VAPID public key), status, subscribe, unsubscribe, test.
 */
export async function handleWebPushAction(
  actorId: string,
  body: Record<string, unknown>,
  serviceClient: SupabaseClient = createServiceRoleClient(),
): Promise<Response> {
  const action = body["web_push_action"];
  const vapid = await resolveVapidConfig(serviceClient);

  if (action === "config") {
    return jsonResponse({ enabled: vapid !== null, public_key: vapid?.publicKey ?? null });
  }
  if (!vapid) throw new FamilyOpsError("INVALID_INPUT", "push notifications are not configured", 400);
  const endpoint = requireEndpoint(body);

  if (action === "status") {
    const stored = await callServerTx<StoredSubscription>(serviceClient, "server_tx_get_web_push_subscription", {
      p_actor_id: actorId, p_endpoint: endpoint,
    });
    return jsonResponse({ registered: Boolean(stored?.active) });
  }
  if (action === "subscribe") {
    const keys = body["keys"] as Record<string, unknown> | undefined;
    const label = typeof body["device_label"] === "string" ? body["device_label"].slice(0, 120) : null;
    if (typeof keys?.p256dh !== "string" || typeof keys?.auth !== "string") {
      throw new FamilyOpsError("INVALID_INPUT", "keys.p256dh and keys.auth are required", 400);
    }
    const result = await callServerTx(serviceClient, "server_tx_upsert_web_push_subscription", {
      p_actor_id: actorId, p_endpoint: endpoint, p_p256dh: keys.p256dh, p_auth: keys.auth, p_device_label: label,
    });
    return jsonResponse(result);
  }
  if (action === "unsubscribe") {
    const result = await callServerTx(serviceClient, "server_tx_delete_web_push_subscription", {
      p_actor_id: actorId, p_endpoint: endpoint,
    });
    return jsonResponse(result);
  }
  if (action === "test") {
    const stored = await callServerTx<StoredSubscription>(serviceClient, "server_tx_get_web_push_subscription", {
      p_actor_id: actorId, p_endpoint: endpoint,
    });
    if (!stored?.active) throw new FamilyOpsError("INVALID_INPUT", "this device is not subscribed", 400);
    const sent = await sendWebPush(stored, {
      title: "おうちノート",
      body: "この端末で通知を受け取れます。",
      url: "/notifications",
      tag: "web-push-test",
    }, vapid, 300);
    if (sent.outcome === "gone") {
      await callServerTx(serviceClient, "server_tx_delete_web_push_subscription", { p_actor_id: actorId, p_endpoint: endpoint });
    }
    if (sent.outcome !== "sent") console.warn("update-notification-preferences: test push failed", { status: sent.status, error: sent.error });
    return jsonResponse({ outcome: sent.outcome });
  }
  throw new FamilyOpsError("INVALID_INPUT", "unknown action", 400);
}
