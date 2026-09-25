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
  rpcImpl: (name: string, args: Record<string, unknown>) => RpcResult | Promise<RpcResult>,
  fromImpl?: (table: string) => unknown,
) {
  const calls: RpcCall[] = [];
  const replies: Reply[] = [];
  const client = {
    rpc: async (name: string, args: Record<string, unknown> = {}) => {
      calls.push({ name, args });
      return await rpcImpl(name, args);
    },
    from: (table: string) => {
      if (!fromImpl) throw new Error(`Unexpected table read: ${table}`);
      return fromImpl(table);
    },
  } as unknown as LineMustCompleteContext["client"];
  const ctx: LineMustCompleteContext = {
    client,
    actorId: "00000000-0000-4000-8000-000000000001",
    householdId: "00000000-0000-4000-8000-000000000002",
    eventId: "line-event-1",
    reply: (text, quickReplies = []) => {
      replies.push({ text, quickReplies });
      return Promise.resolve();
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
  const { ctx, calls, replies } = makeContext((name) => {
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
  const { ctx, calls, replies } = makeContext((name, args) => {
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
  const { ctx, calls, replies } = makeContext((name, args) => {
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

Deno.test("LINE assignment acceptance survives closing the chat before final confirmation", async () => {
  const attempt = { id: "attempt-1", request_id: "request-1", state: "pending",
    acceptance_intent: false, revision: 1, terms_revision: 1,
    reply_due_at: "2026-11-22T10:00:00Z", terms: {}, created_at: "2026-09-25T12:00:00Z" };
  const request = { id: "request-1", request_kind: "assignment_change", shared_title: "お迎え",
    due_at: "2026-11-22T09:00:00Z", assignment_scope: "once",
    requester_actor_ref_id: "actor-requester", recipient_actor_ref_id: "actor-recipient",
    revision: 1, created_at: "2026-09-25T12:00:00Z" };
  const fromImpl = (table: string) => {
    const data = table === "requests" ? [request] : table === "request_attempts" ? [attempt] : null;
    const builder: Record<string, unknown> = {};
    for (const key of ["select", "eq", "is", "or", "in", "order", "limit"])
      builder[key] = () => builder;
    builder.maybeSingle = () => Promise.resolve({ data: { id: "actor-recipient" }, error: null });
    builder.then = (resolve: (value: unknown) => void, reject: (reason: unknown) => void) =>
      Promise.resolve({ data, error: null }).then(resolve, reject);
    return builder;
  };
  const { ctx, calls, replies } = makeContext((name, args) => {
    assertEquals(name, "server_tx_transition_request_v2");
    if (args.p_action === "checking") {
      assertEquals(args.p_terms, { acceptance_intent: true });
      assertEquals(args.p_expected_revision, attempt.revision);
      attempt.state = "checking";
      attempt.acceptance_intent = true;
      attempt.revision += 1;
      return { data: { state: "checking", revision: attempt.revision }, error: null };
    }
    assertEquals(args.p_action, "accept");
    assertEquals(args.p_expected_revision, 2);
    return { data: { state: "accepted" }, error: null };
  }, fromImpl);

  assertEquals(await tryHandleLineMustCompletePostback(ctx, {
    action: "mc_request_prompt_accept", request_id: "request-1", attempt_id: "attempt-1",
    revision: "1", terms_revision: "1",
  }), true);
  assertStringIncludes(replies[0].text, "この担当変更を引き受けますか");
  assertEquals(await tryHandleLineMustCompleteText(ctx, "お願いの返事"), true);
  assertStringIncludes(replies[1].text, "今回だけ");
  assertStringIncludes(replies[1].text, "確定すると、この担当があなたに変わります");
  assert(replies[1].quickReplies.some((action) => action.type === "postback" && action.label === "確定（引受）"));
  assertEquals(await tryHandleLineMustCompletePostback(ctx, {
    action: "mc_request", request_id: "request-1", attempt_id: "attempt-1",
    request_action: "accept", revision: "2", terms_revision: "1",
  }), true);
  assertEquals(calls.map((call) => call.args.p_action), ["checking", "accept"]);
  attempt.acceptance_intent = false;
  assertEquals(await tryHandleLineMustCompletePostback(ctx, {
    action: "mc_request", request_id: "request-1", attempt_id: "attempt-1",
    request_action: "accept", revision: "2", terms_revision: "1",
  }), true);
  assertEquals(calls.length, 2);
  assertStringIncludes(replies.at(-1)?.text ?? "", "最終確認が必要");
  assertEquals(await tryHandleLineMustCompletePostback(ctx, {
    action: "mc_request_prompt_accept", request_id: "request-1", attempt_id: "attempt-1",
    revision: "2", terms_revision: "1",
  }), true);
  assertEquals(attempt.revision, 3);
  assertEquals(calls.map((call) => call.args.p_action), ["checking", "accept", "checking"]);
});

Deno.test("LINE waiting resume preserves revision CAS and canonical source", async () => {
  const { ctx, calls, replies } = makeContext((name, args) => {
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
  const { ctx, calls, replies } = makeContext((name, args) => {
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

Deno.test("LINE anyone task postback uses canonical task claim writer", async () => {
  const { ctx, calls, replies } = makeContext((name, args) => {
    assertEquals(name, "server_tx_task_anyone_claim_v1");
    assertEquals(args.p_task_id, "task-anyone-1");
    assertEquals(args.p_action, "claim");
    assertEquals(args.p_expected_revision, 6);
    assertEquals(args.p_source, "line");
    return { data: { revision: 7 }, error: null };
  });

  assertEquals(await tryHandleLineMustCompletePostback(ctx, {
    action: "mc_task_anyone",
    task_id: "task-anyone-1",
    revision: "6",
    claim_action: "claim",
  }), true);

  assertEquals(calls.map((call) => call.name), ["server_tx_task_anyone_claim_v1"]);
  assertStringIncludes(replies[0].text, "自分がやる");
});

Deno.test("LINE anyone task takeover shows current claimant before mutation", async () => {
  type Builder = {
    select: (columns: string) => Builder;
    eq: (column: string, value: unknown) => Builder;
    is: (column: string, value: unknown) => Builder;
    maybeSingle: () => Promise<{ data: unknown; error: null }>;
  };
  const actorId = "00000000-0000-4000-8000-000000000001";
  const fromImpl = (table: string): Builder => {
    const filters: Record<string, unknown> = {};
    const builder: Builder = {
      select: () => builder,
      eq: (column, value) => {
        filters[column] = value;
        return builder;
      },
      is: (column, value) => {
        filters[column] = value;
        return builder;
      },
      maybeSingle: () => Promise.resolve((() => {
        if (table === "task_instances") {
          return {
            data: {
              id: "task-anyone-1",
              title: "詩乃（便秘）の薬",
              revision: 6,
              status: "todo",
              assignment_mode: "anyone",
              active_claimant_actor_ref_id: "actor-ref-partner",
            },
            error: null,
          };
        }
        if (table === "domain_actor_refs" && filters.real_user_id === actorId) {
          return { data: { id: "actor-ref-self" }, error: null };
        }
        if (table === "domain_actor_refs" && filters.id === "actor-ref-partner") {
          return { data: { real_user_id: "partner-user" }, error: null };
        }
        if (table === "household_members" && filters.user_id === "partner-user") {
          return { data: { family_role: "mama" }, error: null };
        }
        return { data: null, error: null };
      })()),
    };
    return builder;
  };

  const { ctx, calls, replies } = makeContext((name, args) => {
    assertEquals(name, "server_tx_task_anyone_claim_v1");
    assertEquals(args.p_task_id, "task-anyone-1");
    assertEquals(args.p_action, "takeover");
    assertEquals(args.p_expected_revision, 6);
    return { data: { revision: 7 }, error: null };
  }, fromImpl);

  assertEquals(await tryHandleLineMustCompletePostback(ctx, {
    action: "mc_task_anyone",
    task_id: "task-anyone-1",
    revision: "6",
    claim_action: "takeover",
  }), true);

  assertEquals(calls.length, 0);
  assertStringIncludes(replies[0].text, "現在: ママが対応中");
  const confirm = replies[0].quickReplies.find((action) =>
    action.type === "postback" && action.label === "引き継ぐ"
  );
  assert(confirm?.type === "postback");
  assertStringIncludes(confirm.data, "confirmed=true");

  assertEquals(await tryHandleLineMustCompletePostback(ctx, {
    action: "mc_task_anyone",
    task_id: "task-anyone-1",
    revision: "6",
    claim_action: "takeover",
    confirmed: "true",
  }), true);

  assertEquals(calls.map((call) => call.name), ["server_tx_task_anyone_claim_v1"]);
  assertStringIncludes(replies[1].text, "引き継ぎました");
});

Deno.test("LINE one-user simulation entry stays explicitly sandboxed", async () => {
  const { ctx, calls, replies } = makeContext((name) => {
    if (name === "server_tx_get_active_test_simulation_v1") {
      return { data: { active: false }, error: null };
    }
    assertEquals(name, "server_tx_open_test_simulation_interactive_v1");
    return { data: { status: "active" }, error: null };
  });
  assertEquals(await tryHandleLineMustCompleteText(ctx, "1人テスト"), true);
  assertStringIncludes(replies[0].text, "本物の家族へのLINE送信やGoogle更新はしません");
  assert(replies[0].quickReplies.some((action) => action.type === "postback" && action.data.includes("mc_sim_open")));
  assertEquals(await tryHandleLineMustCompletePostback(ctx, { action: "mc_sim_open", role: "mama" }), true);
  assertEquals(calls.map((call) => call.name), ["server_tx_get_active_test_simulation_v1", "server_tx_open_test_simulation_interactive_v1"]);
  assertStringIncludes(replies[1].text, "相手役は 🧪 ママ");
});


Deno.test("LINE one-user simulation shows the actual request instead of developer counters", async () => {
  const { ctx, calls, replies } = makeContext((name) => {
    assertEquals(name, "server_tx_get_test_simulation_workspace_v2");
    return {
      data: {
        status: "active",
        revision: 2,
        simulated_role: "mama",
        simulated_display_label: "🧪 ママ",
        production_side_effects: false,
        tasks: [],
        requests: [{
          title: "お迎えをお願い",
          message: "今日のお迎えをお願いできますか？",
          due_at: "2026-09-11T00:30:00.000Z",
          status: "pending",
          requester_side: "operator",
          recipient_side: "simulated",
          request_id: "request-1",
          latest_attempt: {
            state: "pending",
            attempt_id: "attempt-1",
            revision: 3,
            terms_revision: 1,
            reply_due_at: "2026-09-10T23:30:00.000Z",
          },
        }],
      },
      error: null,
    };
  });

  assertEquals(await tryHandleLineMustCompletePostback(ctx, {
    action: "mc_sim_view",
    test_context_id: "test-context-1",
  }), true);

  assertEquals(calls.map((call) => call.name), ["server_tx_get_test_simulation_workspace_v2"]);
  assertStringIncludes(replies[0].text, "🧪 ママとして確認");
  assertStringIncludes(replies[0].text, "あなたからお願いが届いています");
  assertStringIncludes(replies[0].text, "お迎えをお願い");
  assertStringIncludes(replies[0].text, "内容: 今日のお迎えをお願いできますか？");
  assertStringIncludes(replies[0].text, "返事期限:");
  assertStringIncludes(replies[0].text, "作業期限:");
  assertStringIncludes(replies[0].text, "状態: 返事待ち");
  assert(!replies[0].text.includes("お願い: 1件 / タスク: 0件"));
  assertEquals(replies[0].quickReplies.length, 2);
  assertEquals(replies[0].quickReplies.map((action) => action.label), ["受ける", "断る"]);
  assert(!replies[0].quickReplies.some((action) =>
    action.label.includes("お願い") || action.label.includes("テスト終了")
  ));
});

Deno.test("LINE one-user simulation creates a meaningful role-labelled request", async () => {
  const { ctx, calls, replies } = makeContext((name, args) => {
    if (name === "server_tx_test_simulation_send_request_v1") {
      assertEquals(args.p_direction, "operator_to_simulated");
      assertEquals(args.p_shared_title, "お迎えをお願い");
      assertEquals(args.p_shared_message, "今日のお迎えをお願いできますか？");
      const dueMs = Date.parse(String(args.p_due_at));
      const deltaMs = dueMs - Date.now();
      assert(deltaMs >= 47 * 60 * 60 * 1000);
      assert(deltaMs <= 49 * 60 * 60 * 1000);
      return { data: { status: "pending" }, error: null };
    }
    assertEquals(name, "server_tx_get_active_test_simulation_v1");
    return {
      data: {
        active: true,
        simulated_role: "mama",
        simulated_display_label: "🧪 ママ",
      },
      error: null,
    };
  });

  assertEquals(await tryHandleLineMustCompletePostback(ctx, {
    action: "mc_sim_send",
    test_context_id: "test-context-1",
    direction: "operator_to_simulated",
  }), true);

  assertEquals(calls.map((call) => call.name), [
    "server_tx_test_simulation_send_request_v1",
    "server_tx_get_active_test_simulation_v1",
  ]);
  assertStringIncludes(replies[0].text, "あなた → 🧪 ママ");
  assertStringIncludes(replies[0].text, "お迎えをお願い");
  assert(!replies[0].text.includes("合成した相手"));
});


Deno.test("LINE one-user simulation test state opens the two-action home when no request exists", async () => {
  const { ctx, calls, replies } = makeContext((name) => {
    if (name === "server_tx_get_active_test_simulation_v1") {
      return {
        data: {
          active: true,
          revision: 4,
          test_context_id: "test-context-1",
          simulated_role: "mama",
          simulated_display_label: "🧪 ママ",
        },
        error: null,
      };
    }
    assertEquals(name, "server_tx_get_test_simulation_workspace_v2");
    return {
      data: {
        status: "active",
        revision: 4,
        test_context_id: "test-context-1",
        simulated_role: "mama",
        simulated_display_label: "🧪 ママ",
        production_side_effects: false,
        requests: [],
        tasks: [],
      },
      error: null,
    };
  });

  assertEquals(await tryHandleLineMustCompleteText(ctx, "テスト状態"), true);
  assertEquals(calls.map((call) => call.name), [
    "server_tx_get_active_test_simulation_v1",
    "server_tx_get_test_simulation_workspace_v2",
  ]);
  assertEquals(replies[0].quickReplies.length, 2);
  assertEquals(replies[0].quickReplies.map((action) => action.label), [
    "🧪 ママにお願い",
    "🧪 ママからお願い",
  ]);
  assertStringIncludes(replies[0].text, "まだお願いはありません");
});

Deno.test("LINE one-user simulation can end by text without hidden horizontal button", async () => {
  const { ctx, calls, replies } = makeContext((name, args) => {
    if (name === "server_tx_get_active_test_simulation_v1") {
      return {
        data: {
          active: true,
          revision: 4,
          test_context_id: "test-context-1",
          simulated_role: "mama",
          simulated_display_label: "🧪 ママ",
        },
        error: null,
      };
    }
    assertEquals(name, "server_tx_archive_test_simulation_v1");
    assertEquals(args.p_test_context_id, "test-context-1");
    assertEquals(args.p_expected_revision, 4);
    return { data: { status: "archived" }, error: null };
  });

  assertEquals(await tryHandleLineMustCompleteText(ctx, "テスト終了"), true);
  assertEquals(calls.map((call) => call.name), [
    "server_tx_get_active_test_simulation_v1",
    "server_tx_archive_test_simulation_v1",
  ]);
  assertStringIncludes(replies[0].text, "1人テストを終了しました");
});


Deno.test("LINE one-user simulation test state opens the latest request detail when one exists", async () => {
  const { ctx, calls, replies } = makeContext((name) => {
    if (name === "server_tx_get_active_test_simulation_v1") {
      return {
        data: {
          active: true,
          revision: 4,
          test_context_id: "test-context-1",
          simulated_role: "mama",
          simulated_display_label: "🧪 ママ",
        },
        error: null,
      };
    }
    assertEquals(name, "server_tx_get_test_simulation_workspace_v2");
    return {
      data: {
        status: "active",
        revision: 4,
        simulated_role: "mama",
        simulated_display_label: "🧪 ママ",
        production_side_effects: false,
        requests: [{
          title: "お迎えをお願い",
          message: "今日のお迎えをお願いできますか？",
          due_at: "2026-09-11T00:30:00.000Z",
          status: "pending",
          requester_side: "operator",
          recipient_side: "simulated",
          request_id: "request-1",
          latest_attempt: {
            state: "pending",
            attempt_id: "attempt-1",
            revision: 3,
            terms_revision: 1,
            reply_due_at: "2026-09-10T23:30:00.000Z",
          },
        }],
      },
      error: null,
    };
  });

  assertEquals(await tryHandleLineMustCompleteText(ctx, "テスト状態"), true);
  assertEquals(calls.map((call) => call.name), [
    "server_tx_get_active_test_simulation_v1",
    "server_tx_get_test_simulation_workspace_v2",
  ]);
  assertStringIncludes(replies[0].text, "🧪 ママとして確認");
  assertStringIncludes(replies[0].text, "お迎えをお願い");
  assertEquals(replies[0].quickReplies.map((action) => action.label), ["受ける", "断る"]);
});

Deno.test("LINE one-user simulation accepts a typed role-side alias instead of creating a natural-language draft", async () => {
  const { ctx, calls, replies } = makeContext((name) => {
    if (name === "server_tx_get_active_test_simulation_v1") {
      return {
        data: {
          active: true,
          revision: 4,
          test_context_id: "test-context-1",
          simulated_role: "mama",
          simulated_display_label: "🧪 ママ",
        },
        error: null,
      };
    }
    assertEquals(name, "server_tx_get_test_simulation_workspace_v2");
    return {
      data: {
        status: "active",
        revision: 4,
        simulated_role: "mama",
        simulated_display_label: "🧪 ママ",
        production_side_effects: false,
        requests: [{
          title: "お迎えをお願い",
          message: "今日のお迎えをお願いできますか？",
          due_at: "2026-09-11T00:30:00.000Z",
          status: "pending",
          requester_side: "operator",
          recipient_side: "simulated",
          request_id: "request-1",
          latest_attempt: {
            state: "pending",
            attempt_id: "attempt-1",
            revision: 3,
            terms_revision: 1,
            reply_due_at: "2026-09-10T23:30:00.000Z",
          },
        }],
      },
      error: null,
    };
  });

  assertEquals(await tryHandleLineMustCompleteText(ctx, "🧪 ママ側で確認"), true);
  assertEquals(calls.map((call) => call.name), [
    "server_tx_get_active_test_simulation_v1",
    "server_tx_get_test_simulation_workspace_v2",
  ]);
  assertStringIncludes(replies[0].text, "🧪 ママとして確認");
  assertEquals(replies[0].quickReplies.map((action) => action.label), ["受ける", "断る"]);
});


Deno.test("LINE one-user simulation expired request offers two fresh-test actions", async () => {
  const { ctx, replies } = makeContext((name) => {
    if (name === "server_tx_get_active_test_simulation_v1") {
      return {
        data: {
          active: true,
          revision: 4,
          test_context_id: "test-context-1",
          simulated_role: "mama",
          simulated_display_label: "🧪 ママ",
        },
        error: null,
      };
    }
    assertEquals(name, "server_tx_get_test_simulation_workspace_v2");
    return {
      data: {
        status: "active",
        revision: 4,
        simulated_role: "mama",
        simulated_display_label: "🧪 ママ",
        production_side_effects: false,
        requests: [{
          title: "お迎えをお願い",
          message: "今日のお迎えをお願いできますか？",
          due_at: "2026-09-11T00:30:00.000Z",
          status: "expired",
          requester_side: "operator",
          recipient_side: "simulated",
          request_id: "request-1",
          latest_attempt: {
            state: "expired",
            attempt_id: "attempt-1",
            revision: 3,
            terms_revision: 1,
            reply_due_at: "2026-09-10T23:30:00.000Z",
          },
        }],
      },
      error: null,
    };
  });

  assertEquals(await tryHandleLineMustCompleteText(ctx, "テスト状態"), true);
  assertStringIncludes(replies[0].text, "状態: 返事期限切れ");
  assertEquals(replies[0].quickReplies.map((action) => action.label), [
    "🧪 ママにお願い",
    "🧪 ママからお願い",
  ]);
});
