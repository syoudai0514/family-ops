// Web Push (RFC 8030/8291/8292) to the installed PWA. The encryption and VAPID
// signature come from web-push; delivery and status handling stay here so the
// outcome maps onto server_tx_complete_web_push.
import webpush from "npm:web-push@3.6.7";

export type VapidConfig = { publicKey: string; privateKey: string; subject: string };
export type PushTarget = { endpoint: string; p256dh: string; auth: string };
export type PushMessage = { title: string; body: string; url: string; tag: string | null };
export type PushOutcome = "sent" | "retry" | "gone" | "dead";

function pushSubject(): string | null {
  // Push services require a contact; the app's (or the project's) https URL is enough.
  const subject = Deno.env.get("WEB_PUSH_SUBJECT")?.trim() || Deno.env.get("APP_BASE_URL")?.trim() ||
    Deno.env.get("SUPABASE_URL")?.trim() || "";
  return /^(?:mailto:|https:\/\/)/.test(subject) ? subject : null;
}

export function readVapidConfig(): VapidConfig | null {
  const publicKey = Deno.env.get("WEB_PUSH_VAPID_PUBLIC_KEY")?.trim();
  const privateKey = Deno.env.get("WEB_PUSH_VAPID_PRIVATE_KEY")?.trim();
  const subject = pushSubject();
  if (!publicKey || !privateKey || !subject) return null;
  return { publicKey, privateKey, subject };
}

type VapidKeyStore = {
  rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { message: string } | null }>;
};

/**
 * Secrets win when set. Otherwise the pair kept in private.web_push_vapid_keys is used,
 * created on first need (the deploy token cannot write Edge Function secrets).
 * `create: false` only reads, so a status check never makes keys.
 */
export async function resolveVapidConfig(client: VapidKeyStore, create = true): Promise<VapidConfig | null> {
  const fromEnv = readVapidConfig();
  if (fromEnv) return fromEnv;
  const subject = pushSubject();
  if (!subject) return null;
  const fresh = create ? webpush.generateVAPIDKeys() : null;
  const { data, error } = await client.rpc("server_tx_web_push_vapid_keys", {
    p_public_key: fresh?.publicKey ?? null,
    p_private_key: fresh?.privateKey ?? null,
  });
  if (error) throw new Error(`vapid key store: ${error.message}`);
  const stored = data as { public_key?: string; private_key?: string } | null;
  if (!stored?.public_key || !stored.private_key) return null;
  return { publicKey: stored.public_key, privateKey: stored.private_key, subject };
}

// Only real browser push services. Without this a signed-in user could register
// any https URL and make the worker POST to it.
const PUSH_SERVICE_HOSTS = [
  /^fcm\.googleapis\.com$/,
  /^android\.googleapis\.com$/,
  /^web\.push\.apple\.com$/,
  /^(?:[a-z0-9-]+\.)*push\.services\.mozilla\.com$/,
  /^(?:[a-z0-9-]+\.)*notify\.windows\.com$/,
];

export function isAllowedPushEndpoint(endpoint: string): boolean {
  try {
    const url = new URL(endpoint);
    return url.protocol === "https:" && !url.port && PUSH_SERVICE_HOSTS.some((host) => host.test(url.hostname));
  } catch {
    return false;
  }
}

export function classifyPushStatus(status: number): PushOutcome {
  if (status >= 200 && status < 300) return "sent";
  // 404/410: the browser unsubscribed or the subscription expired.
  if (status === 404 || status === 410) return "gone";
  if (status === 429 || status >= 500) return "retry";
  return "dead";
}

export async function sendWebPush(
  target: PushTarget,
  message: PushMessage,
  vapid: VapidConfig,
  ttlSeconds: number,
  fetchImpl: typeof fetch = fetch,
): Promise<{ outcome: PushOutcome; status: number | null; error?: string }> {
  let details: { endpoint: string; method: string; headers: Record<string, string | number>; body: Uint8Array | null };
  try {
    details = webpush.generateRequestDetails(
      { endpoint: target.endpoint, keys: { p256dh: target.p256dh, auth: target.auth } },
      JSON.stringify(message),
      {
        vapidDetails: vapid,
        TTL: Math.max(0, Math.floor(ttlSeconds)),
        urgency: "high",
      },
    ) as typeof details;
  } catch (error) {
    // Malformed keys cannot become valid by retrying.
    return { outcome: "dead", status: null, error: error instanceof Error ? error.message : "encrypt failed" };
  }
  try {
    const response = await fetchImpl(details.endpoint, {
      method: details.method,
      // web-push hands back numbers (TTL, Content-Length); headers are strings.
      headers: Object.fromEntries(Object.entries(details.headers).map(([key, value]) => [key, String(value)])),
      body: details.body ? new Uint8Array(details.body) : null,
    });
    const text = response.ok ? "" : (await response.text().catch(() => "")).slice(0, 200);
    return { outcome: classifyPushStatus(response.status), status: response.status, error: text || undefined };
  } catch (error) {
    return { outcome: "retry", status: null, error: error instanceof Error ? error.message : "network error" };
  }
}
