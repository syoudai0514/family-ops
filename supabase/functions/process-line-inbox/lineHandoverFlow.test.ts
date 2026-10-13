import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { createClient } from "npm:@supabase/supabase-js@2";
import { handleHandoverAckPostback, isHandoverReviewText, openHandoverReview } from "./lineHandoverFlow.ts";
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";

Deno.test("handover review entry recognizes explicit LINE commands only", () => {
  assertEquals(isHandoverReviewText("共有確認"), true);
  assertEquals(isHandoverReviewText("引き継ぎ確認"), true);
  assertEquals(isHandoverReviewText("確認が必要な共有"), true);
  assertEquals(isHandoverReviewText("共有"), false);
});

function note(overrides: Record<string, unknown> = {}) {
  return {
    id: "pending", shared_text: "食洗機は洗浄中です。終わってから空けてください。", info_kind: "handover",
    revision: 1, author_actor_ref_id: "partner-ref", author_id: "partner",
    valid_from: new Date(Date.now() - 60_000).toISOString(),
    valid_until: new Date(Date.now() + 3_600_000).toISOString(),
    my_acknowledgements: [], ...overrides,
  };
}

function context(rows: Record<string, unknown>[], options: { assertPendingQuery?: boolean; rejectAck?: boolean } = {}) {
  const requests: URL[] = [];
  const replies: Array<{ text: string; actions: LineQuickReplyAction[] }> = [];
  const client = createClient("https://handover.test", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: (input) => {
        const url = new URL(input instanceof Request ? input.url : String(input));
        requests.push(url);
        let data: unknown;
        if (url.pathname.endsWith("/domain_actor_refs")) {
          data = url.searchParams.has("real_user_id") ? { id: "my-ref" } : { real_user_id: "partner", simulated_role: null };
        } else if (url.pathname.endsWith("/household_members")) {
          data = { family_role: "mama" };
        } else if (url.pathname.endsWith("/handovers")) {
          if (options.assertPendingQuery) {
            // These must be server-side predicates, before limit is applied.
            // The fixture represents an older pending note behind ten newer
            // notes already acknowledged by this recipient.
            assertEquals(url.searchParams.get("my_acknowledgements.actor_ref_id"), "eq.my-ref");
            assertEquals(url.searchParams.get("my_acknowledgements.test_context_id"), "is.null");
            assertEquals(url.searchParams.get("my_acknowledgements"), "is.null");
            assertStringIncludes(url.searchParams.get("select") ?? "", "my_acknowledgements:info_acknowledgements(handover_id)");
            assertStringIncludes(url.searchParams.get("valid_from") ?? "", "lte.");
            const predicate = url.searchParams.get("or") ?? "";
            assertStringIncludes(predicate, "valid_until.gt.");
            assertStringIncludes(predicate, "author_actor_ref_id.neq.my-ref");
            assertStringIncludes(predicate, "author_id.neq.me");
          }
          data = rows;
        } else if (url.pathname.endsWith("/rpc/server_tx_ack_info_v1")) {
          if (options.rejectAck) {
            return Promise.resolve(new Response(JSON.stringify({ message: "INFO_ACK_NOT_ACTIONABLE", code: "P0001" }), { status: 400 }));
          }
          data = { acknowledged: true };
        } else {
          throw new Error(`Unexpected handover query: ${url.pathname}`);
        }
        return Promise.resolve(new Response(JSON.stringify(data), { headers: { "Content-Type": "application/json" } }));
      },
    },
  });
  return {
    ctx: {
      client, actorId: "me", householdId: "home", eventId: "event",
      reply: (text: string, actions: LineQuickReplyAction[] = []) => {
        replies.push({ text, actions });
        return Promise.resolve();
      },
    }, requests, replies,
  };
}

Deno.test("review excludes expired, future, canonical own and legacy own notes", async () => {
  const invalid = [
    note({ valid_until: new Date(Date.now() - 1_000).toISOString() }),
    note({ valid_from: new Date(Date.now() + 3_600_000).toISOString() }),
    note({ author_actor_ref_id: "my-ref", author_id: "me" }),
    note({ author_actor_ref_id: null, author_id: "me" }),
  ];
  for (const row of invalid) {
    const { ctx, replies } = context([row]);
    await openHandoverReview(ctx);
    assertEquals(replies.length, 1);
    assertEquals(replies[0].actions, []);
    assertStringIncludes(replies[0].text, "必要な引き継ぎ・共有はありません");
  }
});

Deno.test("review removes already acknowledged and invalid candidates before limit", async () => {
  const { ctx, replies, requests } = context([note({ id: "older-pending" })], { assertPendingQuery: true });
  await openHandoverReview(ctx);
  assertEquals(requests.filter(url => url.pathname.endsWith("/handovers")).length, 1);
  assertEquals(requests.some(url => url.pathname.endsWith("/info_acknowledgements")), false);
  assertStringIncludes(replies[0].text, "ママ → 家族全員");
  assertEquals(replies[0].actions.length, 1);
  assertStringIncludes(JSON.stringify(replies[0].actions[0]), "handover_id=older-pending");
});

Deno.test("indefinite legacy partner note remains reviewable", async () => {
  const { ctx, replies } = context([note({ author_actor_ref_id: null, valid_until: null })]);
  await openHandoverReview(ctx);
  assertEquals(replies[0].actions.length, 1);
});

Deno.test("a stale LINE confirmation reports changed state when DB rejects expiry", async () => {
  const { ctx, replies } = context([], { rejectAck: true });
  assertEquals(await handleHandoverAckPostback(ctx, { action: "mc_handover_ack", handover_id: "expired-note" }), true);
  assertStringIncludes(replies[0].text, "状態が変わっています");
  assertEquals(replies[0].actions, []);
});
