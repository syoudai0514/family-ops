import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

type Handler = (req: Request) => Promise<Response>;
type Turn = { role: "user" | "assistant"; text: string; at: string; actor: string };

// Capture the real worker entrypoint. All database, model and LINE requests are
// intercepted below; fixtures never use a deployed project or a family account.
Deno.test("LINE family roles and contextual pickup corrections never become calendar events", async (t) => {
  const env = {
    SUPABASE_URL: "https://transport-family-http.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "test-service",
    CRON_WORKER_TOKEN: "test-transport-family-worker",
    LINE_CHANNEL_ACCESS_TOKEN: "test-line-token",
    APP_BASE_URL: "https://family-http.example.com",
    GEMINI_API_KEY: "test-gemini-key",
    GEMINI_MODEL_LINE_UNDERSTAND: "family-http-understand",
    GEMINI_MODEL_LINE_DECOMPOSITION: "family-http-decomposition",
  };
  const previous = Object.fromEntries(Object.keys(env).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  const originalFetch = globalThis.fetch;
  const originalServe = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  let handler: Handler | undefined;
  Object.defineProperty(Deno, "serve", { configurable: true, value: (value: Handler) => { handler = value; } });

  const papa = "21000000-0000-4000-8000-000000000001";
  const mama = "21000000-0000-4000-8000-000000000002";
  const household = "31000000-0000-4000-8000-000000000001";
  const task = "41000000-0000-4000-8000-000000000001";
  const pickupDefinition = "51000000-0000-4000-8000-000000000001";
  const previewId = "61000000-0000-4000-8000-000000000001";
  const pendingId = "71000000-0000-4000-8000-000000000001";
  const targetDate = "2026-11-05";
  const baseTime = Date.parse("2026-10-21T04:24:53Z");
  let message = "";
  let postback: string | null = null;
  let event = 0;
  let aiEnabled = true;
  let modelTitle = "11/5の通院";
  let modelDate = "2025-11-05";
  let modelKind: "event" | "task" = "event";
  let modelRewrite: string | null = null;
  let omitUnderstoodDraft = false;
  let decomposedCandidates: Array<Record<string, unknown>> | null = null;
  let historyError = false;
  let occurrenceCount = 1;
  let genericPending: Record<string, unknown> | null = null;
  let genericActionType = "task_create_once";
  const turns: Turn[] = [];
  const calls: Array<{ rpc: string; args: Record<string, unknown> }> = [];
  const replies: Array<Record<string, unknown>> = [];
  const modelPrompts: string[] = [];
  const taskDates: Array<string | null> = [];
  const unexpected: string[] = [];
  const providerError = (code: string) => Response.json({ code: "P0001", message: code }, { status: 400 });

  globalThis.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const body = JSON.parse(String((init as { body?: unknown } | undefined)?.body ?? "{}"));
    if (url.hostname === "api.line.me" && url.pathname === "/v2/bot/message/reply") {
      replies.push(body);
      return Promise.resolve(Response.json({}));
    }
    if (url.hostname === "generativelanguage.googleapis.com") {
      modelPrompts.push(String(body.contents?.[0]?.parts?.[0]?.text ?? ""));
      const generated = url.pathname.includes("family-http-decomposition")
        ? { candidates: decomposedCandidates ?? [{ kind: "task", title: modelTitle, source_text: message, scheduled_date: modelDate,
          due_local_time: null, daypart: null, target_role: "papa", calendar_visibility: "special",
          shared_message: null, confidence: 0.99, missing_fields: [], ambiguous_fields: [] }] }
        : { understanding: "入力した予定を登録", reply: "内容を確認してください", confidence: "high",
          actions: [{ type: "create", text: modelRewrite ?? message, ...(omitUnderstoodDraft ? {} : { draft: {
            kind: modelKind, title: modelTitle, date: modelDate, time: "10:00", daypart: null, who: "me", message: null,
          } }) }] };
      return Promise.resolve(Response.json({ candidates: [{ content: { parts: [{ text: JSON.stringify(generated) }] } }] }));
    }
    if (url.hostname === "transport-family-http.supabase.co") {
      const rpc = url.pathname.split("/rpc/")[1];
      if (rpc) {
        calls.push({ rpc, args: body });
        let result: unknown;
        switch (rpc) {
          case "server_tx_claim_webhook_inbox_batch": result = [{ id: `family-inbox-${event}`, provider_event_id: `family-event-${event}`,
            source_external_user_id: "test-family-line-user", attempts: 1, lease_token: "test-lease", payload: {
              type: postback ? "postback" : "message", timestamp: baseTime + event * 1_000, replyToken: "test-reply",
              ...(postback ? { postback: { data: postback } } : { message: { type: "text", text: message } }),
            } }]; break;
          case "server_tx_resolve_line_actor": result = { user_id: papa, household_id: household }; break;
          case "server_tx_prepare_line_transport_assignment_v1": result = {
            id: previewId, status: "draft", household_id: household, actor_id: papa,
            task_id: task, scheduled_date: targetDate, due_at: `${targetDate}T18:20:00+09:00`, title: "お迎え", code: "pickup",
            current_assignee_user_id: mama, assignee_user_id: papa, current_label: "ママ", target_label: "パパ",
            expected_revision: 7, expires_at: new Date(Date.now() + 15 * 60_000).toISOString(), result: null,
          }; break;
          case "server_read_line_transport_assignment_preview_v1": result = null; break;
          case "server_read_line_turns":
            if (historyError) return Promise.resolve(providerError("INTERNAL_ERROR"));
            result = turns.filter((turn) => turn.actor === body.p_actor_id).slice(-Number(body.p_limit ?? 12)); break;
          case "server_tx_log_line_turn":
            turns.push({ role: body.p_role, text: body.p_text, at: new Date(baseTime + event * 1_000).toISOString(), actor: body.p_actor_id });
            result = { ok: true }; break;
          case "server_tx_get_line_conversation_pending":
          case "server_tx_get_line_pending_text_edit": result = null; break;
          case "server_read_line_understand_enabled": result = aiEnabled; break;
          case "server_read_line_understand_model": result = "family-http-understand"; break;
          case "server_tx_reserve_ai_call": result = true; break;
          case "server_tx_create_pending_action": result = { pending_action_id: pendingId }; break;
          case "server_tx_get_pending_action":
            if (!genericPending) return Promise.resolve(providerError("PENDING_ACTION_NOT_EDITABLE"));
            result = { id: pendingId, status: "draft", action_type: genericActionType, revision: 1, normalized_payload: genericPending }; break;
          case "server_tx_get_week_schedule": result = { assignments: [
            { title: "送り", due_at: `${targetDate}T08:00:00+09:00`, planned_assignee_id: mama },
            { title: "お迎え", due_at: `${targetDate}T18:20:00+09:00`, planned_assignee_id: mama },
          ], occurrences: [] }; break;
          case "server_tx_complete_webhook_inbox_item": result = { ok: true }; break;
          default: unexpected.push(rpc); result = null;
        }
        return Promise.resolve(Response.json(result));
      }
      const table = url.pathname.split("/").at(-1);
      if (table === "household_members") {
        const members = [{ household_id: household, user_id: papa, family_role: "papa" }, { household_id: household, user_id: mama, family_role: "mama" }];
        return Promise.resolve(Response.json(members.filter((member) => url.searchParams.get("user_id") !== `neq.${member.user_id}` &&
          (!url.searchParams.has("family_role") || url.searchParams.get("family_role") === `eq.${member.family_role}`))));
      }
      if (table === "task_definitions") {
        return Promise.resolve(Response.json(url.searchParams.get("code") === "eq.pickup"
          ? [{ id: pickupDefinition, household_id: household, code: "pickup" }] : []));
      }
      if (table === "task_instances" && url.searchParams.get("task_definition_id") === `eq.${pickupDefinition}`) {
        taskDates.push(url.searchParams.get("scheduled_date"));
        return Promise.resolve(Response.json(Array.from({ length: occurrenceCount }, (_, index) => ({
          id: index === 0 ? task : "41000000-0000-4000-8000-000000000002", household_id: household,
          task_definition_id: pickupDefinition, scheduled_date: targetDate, test_context_id: null,
          planned_assignee_id: mama, status: "todo", revision: 7, due_at: `${targetDate}T18:20:00+09:00`, title: "お迎え",
        }))));
      }
      if (["task_instances", "shopping_items", "child_school_contexts", "handovers"].includes(table ?? "")) {
        return Promise.resolve(Response.json([]));
      }
    }
    unexpected.push(url.hostname + url.pathname);
    return Promise.reject(new Error("Unexpected mocked provider request"));
  };

  const run = async (text: string, button: string | null = null) => {
    message = text;
    postback = button;
    event++;
    calls.length = replies.length = modelPrompts.length = unexpected.length = taskDates.length = 0;
    const response = await handler!(new Request("https://edge.example.com/process-line-inbox", { method: "POST",
      headers: { "Content-Type": "application/json", "X-Family-Ops-Worker-Token": env.CRON_WORKER_TOKEN }, body: "{}" }));
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { claimed: 1, succeeded: 1, failed: 0 });
    assertEquals(unexpected, []);
  };
  const rpcCalls = (rpc: string) => calls.filter((call) => call.rpc === rpc);
  const rendered = () => JSON.stringify(replies);
  const seed = (history: Array<{ role: "user" | "assistant"; text: string; actor?: string; at?: string }> = []) => {
    turns.splice(0, turns.length, ...history.map((turn, index) => ({
      ...turn, actor: turn.actor ?? papa, at: turn.at ?? new Date(baseTime - 120_000 + index * 1_000).toISOString(),
    })));
    historyError = false;
    occurrenceCount = 1;
    genericPending = null;
    genericActionType = "task_create_once";
    aiEnabled = true;
    modelTitle = "11/5の通院";
    modelDate = "2025-11-05";
    modelKind = "event";
    modelRewrite = null;
    omitUnderstoodDraft = false;
    decomposedCandidates = null;
  };
  const originalDirective = { role: "user" as const, text: "11/5の迎えを父に変更して。" };
  const scheduleInquiry = { role: "user" as const, text: "11/5の送り迎えおしえて" };
  const assertNoGenericMutation = () => {
    assertEquals(rpcCalls("server_tx_create_pending_action"), []);
    assertEquals(rpcCalls("server_tx_confirm_pending_action"), []);
    assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1"), []);
  };
  const assertActualPickupPreview = () => {
    assertEquals(rpcCalls("server_tx_prepare_line_transport_assignment_v1").length, 1);
    const args = rpcCalls("server_tx_prepare_line_transport_assignment_v1")[0].args;
    assertEquals([args.p_actor_id, args.p_task_id, args.p_assignee_user_id, args.p_expected_revision], [papa, task, papa, 7]);
    assertEquals(taskDates, [`eq.${targetDate}`]);
    assertStringIncludes(rendered(), "11/5(木) 18:20 お迎え");
    assertStringIncludes(rendered(), "現在: ママ → 変更後: パパ");
    assertStringIncludes(rendered(), "lt_agreed_confirm");
    assertEquals(rendered().includes("11/5(水)"), false);
    assertEquals(rendered().includes("18:00"), false);
    assertEquals(modelPrompts, []);
    assertNoGenericMutation();
  };
  try {
    await import("./index.ts");
    Object.defineProperty(Deno, "serve", originalServe);
    await t.step("the exact father directive selects the real 2026 pickup before asking any model", async () => {
      seed();
      await run("11/5の迎えを父に変更して。");
      assertActualPickupPreview();
    });
    await t.step("the original agreement suffix still reviews the exact task and does not auto-confirm", async () => {
      seed();
      await run("11/5の迎えを父に変更して。合意済みです。");
      assertActualPickupPreview();
    });
    await t.step("a schedule inquiry keeps the pickup subject for the user's exact contextual correction", async () => {
      seed([originalDirective, { role: "assistant", text: "確認: 11/5のお迎えを父に変更" },
        { role: "assistant", text: "✓ 登録しました。Googleカレンダーにも入れます。" }]);
      await run("11/5の送り迎えおしえて");
      assertStringIncludes(rendered(), "11/5(木)の予定");
      assertEquals(rpcCalls("server_tx_prepare_line_transport_assignment_v1"), []);
      await run("だからパパに変えてって言ったじゃん");
      assertActualPickupPreview();
      const historyReads = rpcCalls("server_read_line_turns");
      assert(historyReads.some((call) => call.args.p_actor_id === papa && call.args.p_limit === 30));
    });
    await t.step("an assistant's wrong 2025 date cannot override the preceding user's 11/5", async () => {
      seed([originalDirective, { role: "assistant", text: "2025-11-05(水)の予定として登録しました。" }, scheduleInquiry,
        { role: "assistant", text: "11/5(木)の予定\n18:20 お迎え（M）" }]);
      await run("だからパパに変えてって言ったじゃん");
      assertActualPickupPreview();
    });
    for (const [name, history] of [
      ["no source directive", []],
      ["another date inquiry", [originalDirective, { role: "user", text: "11/6の送り迎えおしえて" }]],
      ["another topic", [originalDirective, { role: "user", text: "牛乳を買い物に追加して" }]],
      ["multiple transport candidates", [{ role: "user", text: "11/5の送りと迎えを父に変更して" }]],
      ["assistant-only transport context", [{ role: "assistant", text: "11/5のお迎えをパパに変更します" }]],
      ["another actor's history", [{ ...originalDirective, actor: mama }]],
    ] as Array<[string, Array<{ role: "user" | "assistant"; text: string; actor?: string }> ]>) {
      await t.step(`${name} asks for an explicit target instead of creating a pretend change event`, async () => {
        seed(history);
        await run("だからパパに変えてって言ったじゃん");
        assertEquals(rpcCalls("server_tx_prepare_line_transport_assignment_v1"), []);
        assertEquals(modelPrompts, []);
        assertNoGenericMutation();
        assertStringIncludes(rendered(), "日付");
        assertEquals(rendered().includes("登録しました"), false);
      });
    }
    await t.step("a failed context read cannot fall through to a guessed calendar registration", async () => {
      seed([originalDirective]);
      historyError = true;
      await run("だからパパに変えてって言ったじゃん");
      assertEquals(rpcCalls("server_tx_prepare_line_transport_assignment_v1"), []);
      assertEquals(modelPrompts, []);
      assertNoGenericMutation();
      assertStringIncludes(rendered(), "日付");
    });
    await t.step("multiple actual pickup rows cannot be silently chosen", async () => {
      seed();
      occurrenceCount = 2;
      await run("11/5の迎えを父に変更して。");
      assertEquals(rpcCalls("server_tx_prepare_line_transport_assignment_v1"), []);
      assertNoGenericMutation();
      assertStringIncludes(rendered(), "複数");
      assertEquals(modelPrompts, []);
    });
    for (const raw of ["11/5の迎えを父に変更して。", "だからパパに変えてって言ったじゃん"]) {
      await t.step(`an old misclassified card with ${raw} cannot confirm a new calendar task`, async () => {
        seed();
        genericPending = { title: raw.startsWith("だから") ? "お迎えをパパに変更" : "11/5のお迎えを父に変更",
          raw_text: raw, scheduled_date: "2025-11-05", calendar_visibility: "special", planned_assignee_user_id: papa };
        await run("", `action=confirm_pending&pending_action_id=${pendingId}`);
        assertEquals(rpcCalls("server_tx_confirm_pending_action"), []);
        assertEquals(rpcCalls("server_tx_create_pending_action"), []);
        assertStringIncludes(rendered(), "していません");
        assertEquals(rendered().includes("2025-11-05"), false);
      });
    }
    await t.step("an invented transport title from the model cannot pass the generic creation boundary", async () => {
      seed();
      modelTitle = "お迎えをパパに変更";
      modelDate = targetDate;
      await run("予定を入れて");
      assertEquals(modelPrompts.length, 1);
      assertEquals(rpcCalls("server_tx_prepare_line_transport_assignment_v1"), []);
      assertNoGenericMutation();
      assertEquals(rendered().includes("この内容で登録"), false);
      assertStringIncludes(rendered(), "担当");
    });
    await t.step("an explicit date in a normal event is grounded to the sender's year rather than the model's 2025", async () => {
      seed();
      await run("11/5に通院の予定を入れて");
      assertEquals(modelPrompts.length, 1);
      const creates = rpcCalls("server_tx_create_pending_action");
      assertEquals(creates.length, 1);
      assertEquals(creates[0].args.p_action_type, "task_create_once");
      const payload = creates[0].args.p_normalized_payload as Record<string, unknown>;
      assertEquals(payload.scheduled_date, targetDate);
      assertEquals(payload.title, "11/5の通院");
      assertStringIncludes(rendered(), "11/5(木)");
      assertEquals(rendered().includes("11/5(水)"), false);
    });
    await t.step("a deliberate note about discussing transport remains an ordinary task", async () => {
      seed();
      modelKind = "task";
      modelDate = targetDate;
      modelTitle = "送りの変更についてママに話すメモ";
      await run("送りの変更についてママに話すメモを作る");
      assertEquals(modelPrompts.length, 1);
      assertEquals(rpcCalls("server_tx_prepare_line_transport_assignment_v1"), []);
      assertEquals(rpcCalls("server_tx_create_pending_action").length, 1);
    });
    await t.step("an old multi-intent card cannot confirm an active generic transport-change candidate", async () => {
      seed();
      genericActionType = "line_multi_intent_review";
      genericPending = { raw_text: "11/5のお迎えを父に変更して。通院も追加して", candidates: [
        { candidate_id: "c1", action_type: "task_create_once", status: "draft", title: "お迎えをパパに変更",
          source_text: "11/5のお迎えを父に変更して", missing_fields: [],
          payload: { title: "お迎えをパパに変更", scheduled_date: "2025-11-05", calendar_visibility: "special" } },
        { candidate_id: "c2", action_type: "task_create_once", status: "draft", title: "通院", source_text: "通院も追加して",
          missing_fields: [], payload: { title: "通院", scheduled_date: targetDate } },
      ] };
      await run("", `action=confirm_pending&pending_action_id=${pendingId}`);
      assertNoGenericMutation();
      assertStringIncludes(rendered(), "担当");
      assertStringIncludes(rendered(), "していません");
      assertEquals(rendered().includes("2025-11-05"), false);
    });
    await t.step("semantic multi-intent creation rejects a disguised transport change before storing its review card", async () => {
      seed();
      aiEnabled = false;
      decomposedCandidates = [
        { kind: "task", title: "お迎えをパパに変更", source_text: "予定を二つ入れて", scheduled_date: "2025-11-05",
          calendar_visibility: "special", missing_fields: ["確認"], ambiguous_fields: [], confidence: 0.99 },
        { kind: "task", title: "通院", source_text: "予定を二つ入れて", scheduled_date: "2025-11-05",
          calendar_visibility: "special", missing_fields: [], ambiguous_fields: [], confidence: 0.99 },
      ];
      await run("予定を二つ入れて");
      assertEquals(modelPrompts.length, 1);
      assertNoGenericMutation();
      assertStringIncludes(rendered(), "担当");
      assertEquals(rendered().includes("読み取った内容を確認"), false);
    });
    await t.step("model-rewritten note framing cannot replace the actual source and bypass the multi-intent guard", async () => {
      seed();
      omitUnderstoodDraft = true;
      modelRewrite = "送りの変更についてママに話すメモを作る。通院も追加";
      decomposedCandidates = [
        { kind: "task", title: "お迎えをパパに変更", source_text: "送りの変更についてママに話すメモを作る",
          scheduled_date: "2025-11-05", calendar_visibility: "special", missing_fields: ["確認"], ambiguous_fields: [], confidence: 0.99 },
        { kind: "task", title: "通院", source_text: "通院も追加", scheduled_date: "2025-11-05",
          calendar_visibility: "special", missing_fields: [], ambiguous_fields: [], confidence: 0.99 },
      ];
      await run("必要な予定を入れて");
      assertEquals(modelPrompts.length, 2);
      assertNoGenericMutation();
      assertStringIncludes(rendered(), "担当");
    });
    await t.step("the fallback semantic single-event path also grounds the source month/day instead of 2025", async () => {
      seed();
      aiEnabled = false;
      await run("11/5に通院の予定を入れて");
      assertEquals(modelPrompts.length, 1);
      const creates = rpcCalls("server_tx_create_pending_action");
      assertEquals(creates.length, 1);
      assertEquals(creates[0].args.p_action_type, "task_create_once");
      const payload = creates[0].args.p_normalized_payload as Record<string, unknown>;
      assertEquals(payload.scheduled_date, targetDate);
      assertEquals(payload.raw_text, "11/5に通院の予定を入れて");
    });
    await t.step("semantic multi-intent dates remain grounded separately to each real source clause", async () => {
      seed();
      aiEnabled = false;
      decomposedCandidates = [
        { kind: "task", title: "通院", source_text: "11/5に通院の予定", scheduled_date: "2025-11-05",
          calendar_visibility: "special", missing_fields: [], ambiguous_fields: [], confidence: 0.99 },
        { kind: "task", title: "眼科", source_text: "11/6に眼科の予定を入れて", scheduled_date: "2025-11-06",
          calendar_visibility: "special", missing_fields: [], ambiguous_fields: [], confidence: 0.99 },
      ];
      await run("11/5に通院の予定、11/6に眼科の予定を入れて");
      assertEquals(modelPrompts.length, 1);
      const creates = rpcCalls("server_tx_create_pending_action");
      assertEquals(creates.length, 1);
      assertEquals(creates[0].args.p_action_type, "line_multi_intent_review");
      const payload = creates[0].args.p_normalized_payload as { candidates: Array<{ source_text: string; payload: { scheduled_date: string; raw_text: string } }> };
      assertEquals(payload.candidates.map((candidate) => [candidate.source_text, candidate.payload.raw_text, candidate.payload.scheduled_date]), [
        ["11/5に通院の予定", "11/5に通院の予定", targetDate],
        ["11/6に眼科の予定を入れて", "11/6に眼科の予定を入れて", "2026-11-06"],
      ]);
    });
  } finally {
    Object.defineProperty(Deno, "serve", originalServe);
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) Deno.env.delete(key); else Deno.env.set(key, value);
    }
  }
});
