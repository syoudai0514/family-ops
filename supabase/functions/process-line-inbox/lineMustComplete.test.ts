import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";
import {
  parseStructuredWorkDue,
  tryHandleLineMustCompletePostback,
  tryHandleLineMustCompleteText,
  type LineMustCompleteContext,
} from "./lineMustComplete.ts";

type RpcResult = { data: unknown; error: { message: string } | null };
type RpcCall = { name: string; args: Record<string, unknown> };
type Reply = { text: string; quickReplies: LineQuickReplyAction[] };

function makeContext(
  rpcImpl: (name: string, args: Record<string, unknown>) => Promise<RpcResult>,
) {
  const calls: RpcCall[] = [];
  const replies: Reply[] = [];
  const client = {
    rpc: async (name: string, args: Record<string, unknown> = {}) => {
      calls.push({ name, args });
      return await rpcImpl(name, args);
    },
  } as unknown as LineMustCompleteContext["client"];
  const ctx: LineMustCompleteContext = {
    client,
    actorId: "00000000-0000-4000-8000-000000000001",
    householdId: "00000000-0000-4000-8000-000000000002",
    eventId: "line-event-1",
    reply: async (text, quickReplies = []) => {
      replies.push({ text, quickReplies });
    },
  };
  return { ctx, calls, replies };
}

Deno.test("LINE material deadline parser accepts only explicit structured syntax", () => {
  assertEquals(
    parseStructuredWorkDue("条件期限 2026-09-11 18:30"),
    "2026-09-11T09:30:00.000Z",
  );
  assertEquals(
    parseStructuredWorkDue("条件期限　2026-09-11 18:30"),
    "2026-09-11T09:30:00.000Z",
  );
});

Deno.test("LINE consultation prose is never parsed into a Task mutation", () => {
  assertEquals(parseStructuredWorkDue("18:30ならできる"), null);
  assertEquals(parseStructuredWorkDue("明日は私、金曜は交代"), null);
  assertEquals(parseStructuredWorkDue("送りと迎えを交換"), null);
  assertEquals(parseStructuredWorkDue("条件期限 明日18:30"), null);
});

Deno.test("LINE material deadline parser rejects impossible dates", () => {
  assertEquals(parseStructuredWorkDue("条件期限 2026-02-31 18:30"), null);
  assertEquals(parseStructuredWorkDue("条件期限 2026-09-11 25:00"), null);
});

Deno.test("LINE daily input enters canonical reconciliation and exposes all/mostly/individual", async () => {
  const { ctx, calls, replies } = makeContext(async (name) => {
    assertEquals(name, "server_read_current_routine_sessions");
    return {
      data: { sessions: [{ session_id: "session-1", status: "open", can_act: true }] },
      error: null,
    };
  });
  assertEquals(await tryHandleLineMustCompleteText(ctx, "入力"), true);
  assertEquals(calls[0].name, "server_read_current_routine_sessions");
  const postbacks = replies[0].quickReplies.filter((action) => action.type === "postback");
  assertEquals(postbacks.length, 3);
  assert(postbacks.some((action) => action.type === "postback" && action.data.includes("response_kind=all_done")));
  assert(postbacks.some((action) => action.type === "postback" && action.data.includes("response_kind=mostly_done")));
  assert(postbacks.some((action) => action.type === "postback" && action.data.includes("response_kind=individual")));
});

Deno.test("LINE all-done postback uses canonical reconciliation and returns an undo action", async () => {
  const { ctx, calls, replies } = makeContext(async (name, args) => {
    assertEquals(name, "server_tx_reconcile_routine_session_v2");
    assertEquals(args.p_actor_id, ctx.actorId);
    assertEquals(args.p_session_id, "session-1");
    assertEquals(args.p_response_kind, "all_done");
    return { data: { reconciliation_operation_id: "recon-1", undo_available: true }, error: null };
  });
  assertEquals(await tryHandleLineMustCompletePostback(ctx, {
    action: "mc_reconcile", session_id: "session-1", response_kind: "all_done",
  }), true);
  assertEquals(calls.length, 1);
  assert(replies[0].quickReplies.some((action) => action.type === "postback" && action.data.includes("mc_reconcile_undo") && action.data.includes("recon-1")));
});

Deno.test("LINE request action forwards immutable attempt revisions and fails stale closed", async () => {
  const { ctx, calls, replies } = makeContext(async (name, args) => {
    assertEquals(name, "server_tx_transition_request_v2");
    assertEquals(args.p_expected_revision, 7);
    assertEquals(args.p_expected_terms_revision, 3);
    assertEquals(args.p_source, "line");
    return { data: null, error: { message: "REQUEST_ATTEMPT_STALE" } };
  });
  assertEquals(await tryHandleLineMustCompletePostback(ctx, {
    action: "mc_request",
    request_id: "request-1",
    attempt_id: "attempt-1",
    request_action: "confirm_terms",
    revision: "7",
    terms_revision: "3",
  }), true);
  assertEquals(calls.length, 1);
  assertStringIncludes(replies[0].text, "古くなっています");
});

Deno.test("LINE waiting resume preserves revision CAS and canonical source", async () => {
  const { ctx, calls, replies } = makeContext(async (name, args) => {
    assertEquals(name, "server_tx_set_task_waiting");
    assertEquals(args.p_expected_revision, 11);
    assertEquals(args.p_waiting_action, "resume");
    assertEquals(args.p_source, "line");
    return { data: { revision: 12 }, error: null };
  });
  assertEquals(await tryHandleLineMustCompletePostback(ctx, {
    action: "mc_wait_resume", task_id: "task-1", revision: "11",
  }), true);
  assertEquals(calls.length, 1);
  assertStringIncludes(replies[0].text, "再開しました");
});

Deno.test("LINE shopping discovery uses canonical read model and claim uses canonical writer", async () => {
  const { ctx, calls, replies } = makeContext(async (name, args) => {
    if (name === "server_read_shopping_workspace") {
      assertEquals(args.p_actor_id, ctx.actorId);
      return {
        data: {
          actor_ref_id: "actor-ref-self",
          active: [{
            shopping_item_id: "shop-1",
            title: "牛乳",
            assignment_mode: "anyone",
            active_claimant_actor_ref_id: null,
            revision: 4,
          }],
        },
        error: null,
      };
    }
    assertEquals(name, "server_tx_shopping_claim_v2");
    assertEquals(args.p_shopping_item_id, "shop-1");
    assertEquals(args.p_action, "claim");
    assertEquals(args.p_expected_revision, 4);
    return { data: { revision: 5 }, error: null };
  });
  assertEquals(await tryHandleLineMustCompleteText(ctx, "買い物担当"), true);
  const claim = replies[0].quickReplies.find((action) => action.type === "postback");
  assert(claim?.type === "postback");
  assertStringIncludes(claim.data, "shopping_item_id=shop-1");
  assertEquals(await tryHandleLineMustCompletePostback(ctx, {
    action: "mc_shopping", shopping_item_id: "shop-1", revision: "4", claim_action: "claim",
  }), true);
  assertEquals(calls.map((call) => call.name), ["server_read_shopping_workspace", "server_tx_shopping_claim_v2"]);
});

Deno.test("LINE one-user simulation entry stays explicitly sandboxed", async () => {
  const { ctx, calls, replies } = makeContext(async (name) => {
    if (name === "server_tx_get_active_test_simulation_v1") {
      return { data: { active: false }, error: null };
    }
    assertEquals(name, "server_tx_open_test_simulation_interactive_v1");
    return { data: { status: "active" }, error: null };
  });
  assertEquals(await tryHandleLineMustCompleteText(ctx, "1人テスト"), true);
  assertStringIncludes(replies[0].text, "実LINE送信・Google provider更新はしません");
  assert(replies[0].quickReplies.some((action) => action.type === "postback" && action.data.includes("mc_sim_open")));
  assertEquals(await tryHandleLineMustCompletePostback(ctx, { action: "mc_sim_open", role: "mama" }), true);
  assertEquals(calls.map((call) => call.name), ["server_tx_get_active_test_simulation_v1", "server_tx_open_test_simulation_interactive_v1"]);
  assertStringIncludes(replies[1].text, "1人テストを開始しました");
});
