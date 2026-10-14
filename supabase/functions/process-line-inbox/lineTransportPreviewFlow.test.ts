import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { createClient } from "npm:@supabase/supabase-js@2";
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";
import {
  handleLineTransportPreviewPostback,
  handleLineTransportPreviewText,
  openLineTransportPreview,
} from "./lineTransportPreviewFlow.ts";

const ACTOR = "10000000-0000-4000-8000-000000000001";
const MAMA = "10000000-0000-4000-8000-000000000002";
const HOME = "20000000-0000-4000-8000-000000000001";
const TASK = "30000000-0000-4000-8000-000000000001";
const PREVIEW = "40000000-0000-4000-8000-000000000001";

function row(patch: Record<string, unknown> = {}) {
  return {
    id: PREVIEW,
    status: "draft",
    household_id: HOME,
    actor_id: ACTOR,
    task_id: TASK,
    scheduled_date: "2026-10-15",
    due_at: "2026-10-14T22:30:00Z",
    title: "送り",
    code: "dropoff",
    current_assignee_user_id: MAMA,
    assignee_user_id: ACTOR,
    current_label: "ママ",
    target_label: "パパ",
    expected_revision: 7,
    expires_at: new Date(Date.now() + 15 * 60_000).toISOString(),
    ...patch,
  };
}

function fixture(
  options: {
    preview?: unknown;
    result?: unknown;
    errorRpc?: string;
    errorCode?: string;
  } = {},
) {
  const snapshot = options.preview === undefined ? row() : options.preview;
  const calls: Array<{ rpc: string; args: Record<string, unknown> }> = [];
  const replies: Array<{ text: string; actions: LineQuickReplyAction[] }> = [];
  const turns: Array<{ role: string; text: string; at: string }> = [];
  const client = createClient("https://transport-preview.test", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: (input, init) => {
        const url = new URL(
          input instanceof Request ? input.url : String(input),
        );
        const rpc = url.pathname.split("/rpc/")[1];
        const args = JSON.parse(
          String((init as { body?: unknown } | undefined)?.body ?? "{}"),
        );
        calls.push({ rpc, args });
        if (rpc === options.errorRpc) {
          return Promise.resolve(
            Response.json({
              code: "P0001",
              message: options.errorCode ?? "fixture error",
            }, { status: 400 }),
          );
        }
        let data: unknown;
        if (
          rpc === "server_tx_prepare_line_transport_assignment_v1" ||
          rpc === "server_read_line_transport_assignment_preview_v1"
        ) data = snapshot;
        else if (rpc === "server_read_line_turns") data = turns;
        else if (rpc === "server_tx_decide_line_transport_assignment_v1") {
          data = options.result ?? row({
            status: args.p_action === "cancel" ? "cancelled" : "succeeded",
            result: args.p_action === "cancel"
              ? null
              : { task_id: TASK, revision: 8 },
          });
        } else throw new Error(`Unexpected RPC: ${rpc}`);
        return Promise.resolve(Response.json(data));
      },
    },
  });
  return {
    ctx: {
      client,
      actorId: ACTOR,
      householdId: HOME,
      eventId: "line-event-1",
      reply: (text: string, actions: LineQuickReplyAction[] = []) => {
        replies.push({ text, actions });
        turns.push({ role: "assistant", text, at: new Date().toISOString() });
        return Promise.resolve();
      },
    },
    calls,
    replies,
    turns,
  };
}

const INPUT = { taskId: TASK, assigneeUserId: ACTOR, expectedRevision: 7 };

Deno.test("native transport preview creates an actor-bound snapshot and displays the real occurrence with explicit final buttons", async () => {
  const f = fixture();
  await openLineTransportPreview(f.ctx, INPUT);
  assertEquals(f.calls.length, 1);
  assertEquals(
    f.calls[0].rpc,
    "server_tx_prepare_line_transport_assignment_v1",
  );
  assertEquals(f.calls[0].args.p_actor_id, ACTOR);
  assertEquals(f.calls[0].args.p_task_id, TASK);
  assertEquals(f.calls[0].args.p_assignee_user_id, ACTOR);
  assertEquals(f.calls[0].args.p_expected_revision, 7);
  assertStringIncludes(f.replies[0].text, "担当変更の確認");
  assertStringIncludes(f.replies[0].text, "10/15(木) 07:30 送り");
  assertStringIncludes(f.replies[0].text, "現在: ママ → 変更後: パパ");
  assertStringIncludes(f.replies[0].text, "今回だけ");
  assertStringIncludes(f.replies[0].text, "担当はまだ変更していません");
  assertEquals(f.replies[0].actions.map((action) => action.label), [
    "2人で調整済み・変更する",
    "やめる",
  ]);
  for (const action of f.replies[0].actions) {
    assertEquals(action.label.length <= 20, true);
    if (action.type !== "postback") throw new Error("expected postback");
    assertStringIncludes(action.data, `preview_id=${PREVIEW}`);
  }
  await openLineTransportPreview(f.ctx, INPUT);
  assertEquals(f.calls[0].args.p_operation_id, f.calls[1].args.p_operation_id);
});

Deno.test("the real 確認した済みです follow-up reopens final confirmation and never decides", async () => {
  const f = fixture();
  await openLineTransportPreview(f.ctx, INPUT);
  assertEquals(
    await handleLineTransportPreviewText(f.ctx, "確認した済みです"),
    true,
  );
  assertEquals(f.replies.length, 2);
  assertEquals(f.replies[1].text, f.replies[0].text);
  assertEquals(f.replies[1].actions, f.replies[0].actions);
  assertEquals(f.calls.some((call) => call.rpc.includes("decide")), false);
  assertEquals(
    f.calls.find((call) => call.rpc === "server_read_line_turns")?.args,
    { p_actor_id: ACTOR, p_limit: 4, p_within: "15 minutes" },
  );
});

Deno.test("negative then positive follow-ups remain attached to the same immutable preview", async () => {
  const f = fixture();
  await openLineTransportPreview(f.ctx, INPUT);
  assertEquals(await handleLineTransportPreviewText(f.ctx, "まだです"), true);
  assertStringIncludes(f.replies[1].text, "担当は変更していません");
  assertEquals(f.replies[1].actions.map((action) => action.label), ["やめる"]);
  assertEquals(
    await handleLineTransportPreviewText(f.ctx, "話し合い済み"),
    true,
  );
  assertEquals(f.replies[2].text, f.replies[0].text);
  assertEquals(f.replies[2].actions, f.replies[0].actions);
  assertEquals(f.calls.some((call) => call.rpc.includes("decide")), false);
});

Deno.test("only the explicit final postback calls decide and success requires a committed canonical result", async () => {
  const f = fixture();
  assertEquals(
    await handleLineTransportPreviewPostback(f.ctx, {
      action: "lt_agreed_confirm",
      preview_id: PREVIEW,
      assignee_user_id: MAMA,
    }),
    true,
  );
  assertEquals(f.calls, [{
    rpc: "server_tx_decide_line_transport_assignment_v1",
    args: {
      p_actor_id: ACTOR,
      p_preview_id: PREVIEW,
      p_action: "confirm_agreed",
    },
  }]);
  assertStringIncludes(f.replies[0].text, "✓ 担当を変更しました");
  assertStringIncludes(f.replies[0].text, "ママ → パパ");
  await handleLineTransportPreviewPostback(f.ctx, {
    action: "lt_agreed_confirm",
    preview_id: PREVIEW,
  });
  assertEquals(f.calls.some((call) => call.rpc.includes("prepare")), false);
  assertEquals(f.replies[1].text, f.replies[0].text);
});

Deno.test("cancel does not change assignment and cannot be confused with successful confirmation", async () => {
  const f = fixture();
  assertEquals(
    await handleLineTransportPreviewPostback(f.ctx, {
      action: "lt_cancel",
      preview_id: PREVIEW,
    }),
    true,
  );
  assertEquals(f.calls[0].args.p_action, "cancel");
  assertStringIncludes(f.replies[0].text, "担当は変更していません");
  assertEquals(f.replies[0].text.includes("✓ 担当を変更しました"), false);
});

Deno.test("replaying an original event after success reports its committed result instead of claiming no change", async () => {
  const f = fixture({
    preview: row({
      status: "succeeded",
      result: { task_id: TASK, revision: 8 },
      expires_at: new Date(Date.now() - 1000).toISOString(),
    }),
  });
  await openLineTransportPreview(f.ctx, INPUT);
  assertStringIncludes(f.replies[0].text, "✓ 担当を変更しました");
  assertEquals(f.replies[0].text.includes("担当は変更していません"), false);
  assertEquals(f.replies[0].actions, []);
  const unknown = fixture({
    preview: row({ status: "succeeded", result: null }),
  });
  await openLineTransportPreview(unknown.ctx, INPUT);
  assertStringIncludes(unknown.replies[0].text, "すでに処理済み");
  assertEquals(
    unknown.replies[0].text.includes("担当は変更していません"),
    false,
  );
});

Deno.test("an old cancel button after success never claims that the assignment was unchanged", async () => {
  const f = fixture({
    errorRpc: "server_tx_decide_line_transport_assignment_v1",
    errorCode: "LINE_TRANSPORT_PREVIEW_NOT_ACTIONABLE",
  });
  await handleLineTransportPreviewPostback(f.ctx, {
    action: "lt_cancel",
    preview_id: PREVIEW,
  });
  assertStringIncludes(f.replies[0].text, "すでに処理済み");
  assertEquals(f.replies[0].text.includes("担当は変更していません"), false);
});

Deno.test("a text follow-up reads an already-committed receipt when the previous final-tap reply was lost", async () => {
  const saved = row();
  const f = fixture({ preview: saved });
  await openLineTransportPreview(f.ctx, INPUT);
  Object.assign(saved, {
    status: "succeeded",
    result: { task_id: TASK, revision: 8 },
  });
  assertEquals(
    await handleLineTransportPreviewText(f.ctx, "確認済みです"),
    true,
  );
  assertStringIncludes(f.replies[1].text, "✓ 担当を変更しました");
  assertEquals(f.replies[1].text.includes("担当は変更していません"), false);
  assertEquals(f.calls.some((call) => call.rpc.includes("decide")), false);
});

Deno.test("readbacks from another actor, household, occurrence or target never display a usable confirmation", async () => {
  for (
    const patch of [
      { actor_id: MAMA },
      { household_id: MAMA },
      { task_id: MAMA },
      { assignee_user_id: MAMA },
      { expected_revision: 8 },
      { status: "superseded" },
      { expires_at: new Date(Date.now() - 1000).toISOString() },
    ]
  ) {
    const f = fixture({ preview: row(patch) });
    await openLineTransportPreview(f.ctx, INPUT);
    assertEquals(f.replies[0].actions, []);
    assertEquals(f.calls.some((call) => call.rpc.includes("decide")), false);
  }
});

Deno.test("missing native previews never reconstruct authority from the previous PWA link or text", async () => {
  const f = fixture({ preview: null });
  f.turns.push({
    role: "assistant",
    text:
      "10/15(木) 07:30 送り\n現在: ママ → 変更希望: パパ\n担当はまだ変更していません。",
    at: new Date().toISOString(),
  });
  assertEquals(
    await handleLineTransportPreviewText(f.ctx, "確認済みです"),
    true,
  );
  assertStringIncludes(f.replies[0].text, "もう一度送ってください");
  assertEquals(f.replies[0].actions, []);
  assertEquals(
    f.calls.some((call) =>
      call.rpc.includes("decide") || call.rpc.includes("prepare")
    ),
    false,
  );
});

Deno.test("an unrelated conversation, old context, or a different preview cannot capture a confirmation report", async () => {
  for (const mode of ["unrelated", "old", "new-user", "other-target"]) {
    const f = fixture();
    await openLineTransportPreview(f.ctx, INPUT);
    if (mode === "unrelated") {
      f.turns.push({
        role: "assistant",
        text: "牛乳を買い物に追加しますか？",
        at: new Date().toISOString(),
      });
    }
    if (mode === "old") {
      f.turns[0].at = new Date(Date.now() - 16 * 60_000).toISOString();
    }
    if (mode === "new-user") {
      f.turns.push({
        role: "user",
        text: "牛乳を買って",
        at: new Date().toISOString(),
      });
    }
    if (mode === "other-target") {
      f.turns[0].text = f.turns[0].text.replace("変更後: パパ", "変更後: ママ");
    }
    const handled = await handleLineTransportPreviewText(f.ctx, "確認済みです");
    if (mode === "other-target") {
      assertEquals(handled, true);
      assertStringIncludes(f.replies[1].text, "もう一度送ってください");
    } else {
      assertEquals(handled, false);
      assertEquals(f.replies.length, 1);
    }
    assertEquals(f.calls.some((call) => call.rpc.includes("decide")), false);
  }
});

Deno.test("stale/expired decisions and uncertain network results never produce a success acknowledgement", async () => {
  for (
    const code of [
      "LINE_TRANSPORT_PREVIEW_EXPIRED",
      "AGGREGATE_REVISION_CONFLICT",
      "fixture response unavailable",
    ]
  ) {
    const f = fixture({
      errorRpc: "server_tx_decide_line_transport_assignment_v1",
      errorCode: code,
    });
    await handleLineTransportPreviewPostback(f.ctx, {
      action: "lt_agreed_confirm",
      preview_id: PREVIEW,
    });
    assertEquals(f.replies[0].text.includes("✓ 担当を変更しました"), false);
    assertEquals(f.replies[0].actions, []);
    if (code.includes("unavailable")) {
      assertStringIncludes(f.replies[0].text, "同じ確認ボタン");
    }
  }
  for (
    const result of [
      row({ status: "succeeded", result: null }),
      row({ status: "succeeded", result: { task_id: MAMA, revision: 8 } }),
      row({ status: "succeeded", result: { task_id: TASK, revision: 7 } }),
    ]
  ) {
    const f = fixture({ result });
    await handleLineTransportPreviewPostback(f.ctx, {
      action: "lt_agreed_confirm",
      preview_id: PREVIEW,
    });
    assertEquals(f.replies[0].text.includes("✓ 担当を変更しました"), false);
  }
});

Deno.test("a context read failure asks for the target instead of replying with an unverified 了解", async () => {
  const f = fixture({ errorRpc: "server_read_line_turns" });
  assertEquals(
    await handleLineTransportPreviewText(f.ctx, "確認した済みです"),
    true,
  );
  assertStringIncludes(f.replies[0].text, "担当は変更していません");
  assertEquals(f.calls.some((call) => call.rpc.includes("decide")), false);
});

Deno.test("unrelated text/postbacks and invalid preview IDs never make transport commands", async () => {
  const f = fixture();
  assertEquals(
    await handleLineTransportPreviewText(f.ctx, "確認済みですか？"),
    false,
  );
  assertEquals(await handleLineTransportPreviewText(f.ctx, "はい"), false);
  assertEquals(
    await handleLineTransportPreviewPostback(f.ctx, {
      action: "confirm_pending",
      preview_id: PREVIEW,
    }),
    false,
  );
  assertEquals(f.calls, []);
  assertEquals(
    await handleLineTransportPreviewPostback(f.ctx, {
      action: "lt_agreed_confirm",
      preview_id: "invalid",
    }),
    true,
  );
  assertEquals(f.calls, []);
});
