import { assertEquals, assertMatch } from "jsr:@std/assert@1";
import webpush from "npm:web-push@3.6.7";
import { classifyPushStatus, isAllowedPushEndpoint, sendWebPush } from "./webPush.ts";

function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function browserKeys() {
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  return { p256dh: base64Url(raw), auth: base64Url(crypto.getRandomValues(new Uint8Array(16))) };
}

Deno.test("only browser push services are accepted as endpoints", () => {
  assertEquals(isAllowedPushEndpoint("https://web.push.apple.com/QGx1"), true);
  assertEquals(isAllowedPushEndpoint("https://fcm.googleapis.com/fcm/send/abc"), true);
  assertEquals(isAllowedPushEndpoint("https://updates.push.services.mozilla.com/wpush/v2/x"), true);
  assertEquals(isAllowedPushEndpoint("https://wns2-par02p.notify.windows.com/w/?token=x"), true);
  assertEquals(isAllowedPushEndpoint("http://fcm.googleapis.com/fcm/send/abc"), false);
  assertEquals(isAllowedPushEndpoint("https://fcm.googleapis.com:8443/x"), false);
  assertEquals(isAllowedPushEndpoint("https://evil.example.com/fcm.googleapis.com"), false);
  assertEquals(isAllowedPushEndpoint("https://web.push.apple.com.evil.example/x"), false);
  assertEquals(isAllowedPushEndpoint("not a url"), false);
});

Deno.test("push service status codes map to retry policy", () => {
  assertEquals(classifyPushStatus(201), "sent");
  assertEquals(classifyPushStatus(410), "gone");
  assertEquals(classifyPushStatus(404), "gone");
  assertEquals(classifyPushStatus(429), "retry");
  assertEquals(classifyPushStatus(503), "retry");
  assertEquals(classifyPushStatus(403), "dead");
  assertEquals(classifyPushStatus(413), "dead");
});

Deno.test("sends an encrypted, VAPID-signed request and reports the outcome", async () => {
  const vapidKeys = webpush.generateVAPIDKeys();
  const vapid = { publicKey: vapidKeys.publicKey, privateKey: vapidKeys.privateKey, subject: "mailto:family@example.com" };
  const keys = await browserKeys();
  const seen: Array<{ url: string; init: RequestInit }> = [];
  const fakeFetch = ((url: string, init: RequestInit) => {
    seen.push({ url, init });
    return Promise.resolve(new Response(null, { status: seen.length === 1 ? 201 : 410 }));
  }) as unknown as typeof fetch;
  const target = { endpoint: "https://web.push.apple.com/abc", ...keys };
  const message = { title: "歯医者", body: "あと30分", url: "/month?date=2026-10-20", tag: "schedule-1" };

  const first = await sendWebPush(target, message, vapid, 3600, fakeFetch);
  assertEquals(first.outcome, "sent");
  const headers = seen[0].init.headers as Record<string, string>;
  assertEquals(seen[0].url, target.endpoint);
  assertEquals(headers["Content-Encoding"], "aes128gcm");
  assertEquals(headers["TTL"], "3600");
  assertMatch(headers["Authorization"], /^vapid t=.+, k=.+/);
  // The plaintext never travels as-is.
  const body = new TextDecoder().decode(seen[0].init.body as Uint8Array);
  assertEquals(body.includes("歯医者"), false);

  assertEquals((await sendWebPush(target, message, vapid, 3600, fakeFetch)).outcome, "gone");
  assertEquals((await sendWebPush({ ...target, p256dh: "broken" }, message, vapid, 3600, fakeFetch)).outcome, "dead");
  const offline = (() => Promise.reject(new Error("offline"))) as unknown as typeof fetch;
  assertEquals((await sendWebPush(target, message, vapid, 3600, offline)).outcome, "retry");
});
