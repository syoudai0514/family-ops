import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

type Handler = (req: Request) => Promise<Response>;

// Exercise the real worker handler. Every provider and database request is caught
// by this fetch stub; no deployed project, LINE account or Gemini key is used.
Deno.test("LINE worker HTTP keeps closed input history separate from new requests", async (t) => {
  const env = {
    SUPABASE_URL: "https://closed-context-test.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "test-service",
    CRON_WORKER_TOKEN: "closed-context-test-worker",
    LINE_CHANNEL_ACCESS_TOKEN: "test-line-token",
    APP_BASE_URL: "https://family-test.example.com",
    GEMINI_API_KEY: "test-gemini-key",
    GEMINI_MODEL_LINE_UNDERSTAND: "context-http-understand",
    GEMINI_MODEL_LINE_DECOMPOSITION: "context-http-decomposition",
  };
  const previous = Object.fromEntries(Object.keys(env).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  const originalFetch = globalThis.fetch;
  const originalServe = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  let handler: Handler | undefined;
  Object.defineProperty(Deno, "serve", { configurable: true, value: (value: Handler) => { handler = value; } });
  const actorId = "20000000-0000-4000-8000-000000000001";
  const partnerId = "20000000-0000-4000-8000-000000000002";
  const householdId = "30000000-0000-4000-8000-000000000001";
  const closedId = "40000000-0000-4000-8000-000000000001";
  const tomorrow = new Date(Date.now() + (9 + 24) * 3600_000).toISOString().slice(0, 10);
  let text = "";
  let postback: string | null = null;
  let aiEnabled = false;
  let planMode: "create" | "edit_draft" | "legacy" = "legacy";
  let genericConfirm = false;
  let genericActionType = "request_create";
  let genericRawText = "明日の送りは私に変更してください";
  let transportDate = tomorrow;
  let transportCode = "dropoff";
  let transportAssignee = partnerId;
  let eventNumber = 0;
  const calls: Array<{ rpc: string; args: Record<string, unknown> }> = [];
  const replies: Array<Record<string, unknown>> = [];
  const prompts: string[] = [];
  const unexpected: string[] = [];
  const taskReadDates: string[] = [];
  globalThis.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const body = JSON.parse(String((init as { body?: unknown } | undefined)?.body ?? "{}"));
    if (url.hostname === "api.line.me" && url.pathname === "/v2/bot/message/reply") {
      replies.push(body);
      return Promise.resolve(Response.json({}));
    }
    if (url.hostname === "generativelanguage.googleapis.com") {
      const prompt = body.contents[0].parts[0].text as string;
      prompts.push(prompt);
      const generated = url.pathname.includes("context-http-decomposition")
        ? { candidates: [{ kind: "request", title: "明日の買い物をママにお願い", source_text: text, scheduled_date: tomorrow,
          target_role: "mama", shared_message: "明日の買い物をお願いできますか？", confidence: 0.99, missing_fields: [], ambiguous_fields: [] }] }
        : { understanding: "新しい用件", reply: "了解", confidence: "high", actions: [{ type: planMode, text,
          ...(planMode === "legacy" ? {} : { draft: { kind: "request", title: "明日の買い物をママにお願い", date: tomorrow,
            time: null, daypart: null, who: "partner", message: "明日の買い物をお願いできますか？" } }) }] };
      return Promise.resolve(Response.json({ candidates: [{ content: { parts: [{ text: JSON.stringify(generated) }] } }] }));
    }
    if (url.hostname === "closed-context-test.supabase.co") {
      const rpc = url.pathname.split("/rpc/")[1];
      if (rpc) {
        calls.push({ rpc, args: body });
        let data: unknown;
        switch (rpc) {
          case "server_tx_claim_webhook_inbox_batch": data = [{ id: `inbox-${eventNumber}`, provider_event_id: `event-${eventNumber}`,
            source_external_user_id: "test-line-user", attempts: 1, lease_token: "test-lease", payload: {
              type: postback ? "postback" : "message", ...(postback ? { postback: { data: postback } } : { message: { type: "text", text } }), replyToken: "test-reply",
            } }]; break;
          case "server_tx_resolve_line_actor": data = { user_id: actorId, household_id: householdId }; break;
          case "server_tx_get_line_conversation_pending": data = { id: closedId, status: "succeeded", action_type: "task_create_once",
            normalized_payload: { title: "詩乃の検尿チャレンジ", scheduled_date: tomorrow }, revision: 2 }; break;
          case "server_read_line_understand_enabled": data = aiEnabled; break;
          case "server_read_line_understand_model": data = "context-http-understand"; break;
          case "server_tx_reserve_ai_call": data = true; break;
          case "server_read_line_turns": data = [{ role: "assistant", text: "✓ 登録しました。" }]; break;
          case "server_tx_get_line_pending_text_edit": data = null; break;
          case "server_tx_create_pending_action": data = { pending_action_id: "40000000-0000-4000-8000-000000000002" }; break;
          case "server_tx_prepare_line_transport_assignment_v1": data = {
            id: "50000000-0000-4000-8000-000000000001", status: "draft", household_id: householdId, actor_id: actorId,
            task_id: "60000000-0000-4000-8000-000000000001", scheduled_date: transportDate, due_at: `${transportDate}T08:00:00+09:00`,
            title: "送り", code: "dropoff", current_assignee_user_id: partnerId, assignee_user_id: actorId,
            current_label: "ママ", target_label: "パパ", expected_revision: 1,
            expires_at: new Date(Date.now() + 15 * 60_000).toISOString(),
          }; break;
          case "server_tx_get_pending_action":
            if (genericConfirm) {
              data = { id: closedId, status: "draft", action_type: genericActionType, revision: 0,
                normalized_payload: { title: "送り・お迎え担当を変更", raw_text: genericRawText, scheduled_date: transportDate, recipient_user_id: partnerId } };
              break;
            }
            return Promise.resolve(Response.json({ code: "P0001", message: "PENDING_ACTION_NOT_EDITABLE" }, { status: 400 }));
          case "server_tx_log_line_turn":
          case "server_tx_complete_webhook_inbox_item": data = { ok: true }; break;
          default: unexpected.push(rpc); data = null;
        }
        return Promise.resolve(Response.json(data));
      }
      const table = url.pathname.split("/").at(-1);
      if (table === "household_members") {
        const members = [{ household_id: householdId, user_id: actorId, family_role: "papa" }, { household_id: householdId, user_id: partnerId, family_role: "mama" }];
        const rows = members.filter((m) => (!url.searchParams.has("family_role") || url.searchParams.get("family_role") === `eq.${m.family_role}`)
          && url.searchParams.get("user_id") !== `neq.${m.user_id}`);
        return Promise.resolve(Response.json(rows));
      }
      if (table === "task_definitions" && url.searchParams.get("code") === `eq.${transportCode}`) {
        return Promise.resolve(Response.json([{ id: "transport-definition", household_id: householdId, code: transportCode }]));
      }
      if (table === "task_instances" && url.searchParams.get("task_definition_id") === "eq.transport-definition") {
        taskReadDates.push(url.searchParams.get("scheduled_date") ?? "");
        return Promise.resolve(Response.json([{ id: "60000000-0000-4000-8000-000000000001", household_id: householdId, task_definition_id: "transport-definition",
          scheduled_date: transportDate, planned_assignee_id: transportAssignee, status: "todo", revision: 1, due_at: `${transportDate}T08:00:00+09:00`, test_context_id: null }]));
      }
      if (["task_instances", "task_definitions", "shopping_items", "child_school_contexts", "handovers"].includes(table ?? "")) {
        return Promise.resolve(Response.json([]));
      }
    }
    unexpected.push(url.hostname + url.pathname);
    return Promise.reject(new Error("Unexpected mocked provider request"));
  };
  const run = async (message: string) => {
    text = message;
    eventNumber++;
    calls.length = replies.length = prompts.length = unexpected.length = taskReadDates.length = 0;
    const response = await handler!(new Request("https://edge.example.com/process-line-inbox", { method: "POST",
      headers: { "Content-Type": "application/json", "X-Family-Ops-Worker-Token": env.CRON_WORKER_TOKEN }, body: "{}" }));
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { claimed: 1, succeeded: 1, failed: 0 });
    assertEquals(unexpected, []);
  };
  const pendingCalls = () => calls.filter((call) => call.rpc === "server_tx_create_pending_action");
  const rendered = () => JSON.stringify(replies);
  try {
    await import("./index.ts");
    Object.defineProperty(Deno, "serve", originalServe);
    await t.step("worker authentication rejects before any provider request", async () => {
      const response = await handler!(new Request("https://edge.example.com/process-line-inbox", { method: "POST", body: "{}" }));
      assertEquals(response.status, 401);
      assertEquals(calls, []);
    });
    await t.step("fallback creates a fresh family request rather than replying about the completed urine-check input", async () => {
      await run("明日の買い物をママに変更して");
      assertEquals(pendingCalls().length, 1);
      assertEquals(pendingCalls()[0].args.p_action_type, "request_create");
      const payload = pendingCalls()[0].args.p_normalized_payload as Record<string, unknown>;
      assertEquals(payload.recipient_user_id, partnerId);
      assertEquals(payload.scheduled_date, tomorrow);
      assertEquals(payload.title, "明日の買い物をママにお願い");
      assertEquals(rendered().includes("登録済み"), false);
      assertStringIncludes(rendered(), "この内容で送る");
      assertEquals(calls.some((call) => /update_pending|confirm_pending|send_request/.test(call.rpc)), false);
    });
    await t.step("AI receives no closed draft and creates a fresh confirmation card", async () => {
      aiEnabled = true;
      planMode = "create";
      await run("明日の買い物をママに変更して");
      assert(prompts.some((prompt) => prompt.includes('"確認待ちの下書き":null')));
      assertEquals(pendingCalls().length, 1);
      assertEquals(rendered().includes("登録済み"), false);
    });
    await t.step("the screenshot transport change reads the actual schedule without creating a generic request", async () => {
      planMode = "legacy";
      await run("明日の送りは私に変更してください");
      assertEquals(pendingCalls().length, 0);
      assertEquals(rendered().includes("登録済み"), false);
      assertStringIncludes(rendered(), "送り");
      assertStringIncludes(rendered(), "ママ");
      assertStringIncludes(rendered(), "パパ");
      assertStringIncludes(rendered(), "今回だけ");
      assertStringIncludes(rendered(), "調整済み");
      assertStringIncludes(rendered(), "lt_agreed_confirm");
    });
    await t.step("a genuine correction of the registered input stays a safe historical response", async () => {
      aiEnabled = false;
      await run("さっきの詩乃の検尿チャレンジを明日に変更して");
      assertEquals(pendingCalls().length, 0);
      assertStringIncludes(rendered(), "登録済み");
      assertEquals(calls.some((call) => /update_pending|confirm_pending|send_request/.test(call.rpc)), false);
    });
    await t.step("an AI create proposal cannot duplicate an explicitly referenced completed input", async () => {
      aiEnabled = true;
      planMode = "create";
      await run("さっきの詩乃の検尿チャレンジを明日に変更して");
      assertEquals(pendingCalls().length, 0);
      assertStringIncludes(rendered(), "登録済み");
    });
    await t.step("replaying the old confirm button cannot register another input", async () => {
      postback = `action=confirm_pending&pending_action_id=${closedId}`;
      await run("");
      assertEquals(pendingCalls().length, 0);
      assertStringIncludes(rendered(), "すでに確定");
      assertEquals(calls.some((call) => call.rpc === "server_tx_confirm_pending_action"), false);
    });
    await t.step("an old generic dropoff request card refuses without promoting its model-filled date", async () => {
      genericConfirm = true;
      transportDate = new Date(Date.parse(`${tomorrow}T00:00:00Z`) + 7 * 86400_000).toISOString().slice(0, 10);
      await run("");
      assertEquals(pendingCalls().length, 0);
      assertEquals(calls.some((call) => call.rpc === "server_tx_confirm_pending_action"), false);
      assertStringIncludes(rendered(), "送信・登録はしていません");
      assertStringIncludes(rendered(), "担当は変更できません");
      assertEquals(rendered().includes(transportDate), false);
      assertEquals(taskReadDates, []);
    });
    await t.step("an old generic pickup task card also requires review instead of confirming a duplicate task", async () => {
      genericActionType = "task_create_once";
      genericRawText = "明日のお迎えをママに変更して";
      transportCode = "pickup";
      transportAssignee = actorId;
      await run("");
      assertEquals(pendingCalls().length, 0);
      assertEquals(calls.some((call) => call.rpc === "server_tx_confirm_pending_action"), false);
      assertStringIncludes(rendered(), "送信・登録はしていません");
      assertStringIncludes(rendered(), "担当は変更できません");
      assertEquals(rendered().includes(transportDate), false);
      assertEquals(taskReadDates, []);
    });
  } finally {
    Object.defineProperty(Deno, "serve", originalServe);
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) Deno.env.delete(key); else Deno.env.set(key, value);
    }
  }
});
