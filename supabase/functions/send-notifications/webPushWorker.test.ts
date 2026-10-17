import { assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { processWebPushOutbox } from "./webPushWorker.ts";

const vapid = { publicKey: "pub", privateKey: "priv", subject: "mailto:family@example.com" };

Deno.test("each claimed device push is sent once and its outcome recorded", async () => {
  const calls: Array<{ fn: string; args: Record<string, unknown> }> = [];
  const rows = [
    { outbox_id: "a", endpoint: "https://web.push.apple.com/a", p256dh: "k", auth: "s", title: "歯医者", body: "あと30分", url: "/month", tag: "t", expires_at: "2026-10-20T05:00:00Z" },
    { outbox_id: "b", endpoint: "https://fcm.googleapis.com/b", p256dh: "k", auth: "s", title: "遠足", body: "明日", url: "/month", tag: null, expires_at: "2026-10-20T04:00:30Z" },
  ];
  const client = {
    rpc: (fn: string, args: Record<string, unknown>) => {
      calls.push({ fn, args });
      return Promise.resolve(fn === "server_tx_claim_web_push_batch" ? { data: rows, error: null } : { data: null, error: null });
    },
  } as unknown as SupabaseClient;
  const ttls: number[] = [];
  const send = ((target: { endpoint: string }, _message: unknown, _vapid: unknown, ttl: number) => {
    ttls.push(ttl);
    return Promise.resolve(target.endpoint.includes("apple")
      ? { outcome: "sent" as const, status: 201 }
      : { outcome: "gone" as const, status: 410, error: "expired" });
  }) as unknown as Parameters<typeof processWebPushOutbox>[2];

  const summary = await processWebPushOutbox(client, vapid, send, () => Date.parse("2026-10-20T04:00:00Z"));
  assertEquals(summary, { claimed: 2, sent: 1, retry: 0, gone: 1, dead: 0 });
  assertEquals(ttls, [3600, 60]);
  assertEquals(
    calls.filter((call) => call.fn === "server_tx_complete_web_push").map((call) => [call.args.p_outbox_id, call.args.p_outcome, call.args.p_error]),
    [["a", "sent", "201"], ["b", "gone", "expired"]],
  );
});
