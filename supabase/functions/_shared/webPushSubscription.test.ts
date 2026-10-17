import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { handleWebPushAction } from "./webPushSubscription.ts";

function keyStore() {
  let stored: { public_key: string; private_key: string } | null = null;
  const calls: Array<Record<string, unknown>> = [];
  const client = {
    rpc: (_fn: string, args: Record<string, unknown>) => {
      calls.push(args);
      if (!stored && typeof args.p_public_key === "string") {
        stored = { public_key: args.p_public_key, private_key: String(args.p_private_key) };
      }
      return Promise.resolve({ data: stored, error: null });
    },
  } as unknown as SupabaseClient;
  return { client, calls };
}

Deno.test("config creates one key pair on first use and reuses it", async () => {
  Deno.env.set("SUPABASE_URL", "https://example.supabase.co");
  const { client, calls } = keyStore();
  const first = await (await handleWebPushAction("user-1", { web_push_action: "config" }, client)).json();
  const second = await (await handleWebPushAction("user-1", { web_push_action: "config" }, client)).json();
  assertEquals(first.enabled, true);
  assertEquals(typeof first.public_key, "string");
  assertEquals(second.public_key, first.public_key);
  assertEquals(calls.length, 2);
});

Deno.test("environment keys win over stored ones", async () => {
  Deno.env.set("WEB_PUSH_VAPID_PUBLIC_KEY", "public-from-env");
  Deno.env.set("WEB_PUSH_VAPID_PRIVATE_KEY", "private-from-env");
  try {
    const { client, calls } = keyStore();
    const config = await (await handleWebPushAction("user-1", { web_push_action: "config" }, client)).json();
    assertEquals(config, { enabled: true, public_key: "public-from-env" });
    assertEquals(calls.length, 0);
  } finally {
    Deno.env.delete("WEB_PUSH_VAPID_PUBLIC_KEY");
    Deno.env.delete("WEB_PUSH_VAPID_PRIVATE_KEY");
  }
});

Deno.test("subscribing to a non push-service URL is refused before any database write", async () => {
  const { client } = keyStore();
  await assertRejects(() =>
    handleWebPushAction("user-1", {
      web_push_action: "subscribe",
      endpoint: "https://internal.example.com/hook",
      keys: { p256dh: "k", auth: "a" },
    }, client)
  );
});
