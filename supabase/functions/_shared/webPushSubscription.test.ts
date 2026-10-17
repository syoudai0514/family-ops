import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { handleWebPushAction } from "./webPushSubscription.ts";

Deno.test("config reports push as unavailable until VAPID keys exist", async () => {
  Deno.env.delete("WEB_PUSH_VAPID_PUBLIC_KEY");
  Deno.env.delete("WEB_PUSH_VAPID_PRIVATE_KEY");
  const response = await handleWebPushAction("user-1", { web_push_action: "config" });
  assertEquals(await response.json(), { enabled: false, public_key: null });
});

Deno.test("subscribing to a non push-service URL is refused before any database call", async () => {
  Deno.env.set("WEB_PUSH_VAPID_PUBLIC_KEY", "public");
  Deno.env.set("WEB_PUSH_VAPID_PRIVATE_KEY", "private");
  Deno.env.set("WEB_PUSH_SUBJECT", "https://family-ops-web.vercel.app");
  try {
    const config = await handleWebPushAction("user-1", { web_push_action: "config" });
    assertEquals(await config.json(), { enabled: true, public_key: "public" });
    await assertRejects(() =>
      handleWebPushAction("user-1", {
        web_push_action: "subscribe",
        endpoint: "https://internal.example.com/hook",
        keys: { p256dh: "k", auth: "a" },
      })
    );
  } finally {
    Deno.env.delete("WEB_PUSH_VAPID_PUBLIC_KEY");
    Deno.env.delete("WEB_PUSH_VAPID_PRIVATE_KEY");
    Deno.env.delete("WEB_PUSH_SUBJECT");
  }
});
