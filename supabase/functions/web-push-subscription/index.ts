// verify_jwt=true. Turns push notifications on/off for the signed-in user's device.
// Actions: config (VAPID public key), status, subscribe, unsubscribe, test.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { jsonResponse, withUserMutationHandler } from "../_shared/handler.ts";
import { callServerTx, readJsonBody } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import { isAllowedPushEndpoint, readVapidConfig, sendWebPush } from "../_shared/webPush.ts";

type StoredSubscription = { subscription_id: string; endpoint: string; p256dh: string; auth: string; active: boolean } | null;

function requireEndpoint(body: Record<string, unknown>): string {
  const endpoint = body["endpoint"];
  if (typeof endpoint !== "string" || !isAllowedPushEndpoint(endpoint)) {
    throw new FamilyOpsError("INVALID_INPUT", "endpoint is not a supported push service", 400);
  }
  return endpoint;
}

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const action = body["action"];
  const vapid = readVapidConfig();
  const serviceClient = createServiceRoleClient();

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
    if (sent.outcome !== "sent") console.warn("web-push-subscription: test push failed", { status: sent.status, error: sent.error });
    return jsonResponse({ outcome: sent.outcome });
  }
  throw new FamilyOpsError("INVALID_INPUT", "unknown action", 400);
}));
