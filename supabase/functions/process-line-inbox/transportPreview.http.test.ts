import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

type Handler = (req: Request) => Promise<Response>;
type Preview = Record<string, unknown>;
type Turn = { role: string; text: string; at: string; actor: string };

// Only the actual worker request handler runs. Every outbound request is caught
// by fetch below: no deployed database, LINE user or model is contacted.
Deno.test("LINE transport agreement preview survives follow-up and confirms only its server-issued ID", async (t) => {
  const env = {
    SUPABASE_URL: "https://transport-preview-test.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "test-service",
    CRON_WORKER_TOKEN: "test-transport-worker",
    LINE_CHANNEL_ACCESS_TOKEN: "test-line-token",
    APP_BASE_URL: "https://family-test.example.com",
  };
  const previous = Object.fromEntries(Object.keys(env).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  const originalFetch = globalThis.fetch;
  const originalServe = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  let handler: Handler | undefined;
  Object.defineProperty(Deno, "serve", { configurable: true, value: (value: Handler) => { handler = value; } });
  const papa = "20000000-0000-4000-8000-000000000001";
  const mama = "20000000-0000-4000-8000-000000000002";
  const household = "30000000-0000-4000-8000-000000000001";
  const task = "40000000-0000-4000-8000-000000000001";
  const definition = "50000000-0000-4000-8000-000000000001";
  const previewId = "60000000-0000-4000-8000-000000000001";
  const today = new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10);
  const originalPreview: Preview = {
    id: previewId, status: "draft", household_id: household, actor_id: papa, task_id: task,
    scheduled_date: today, due_at: `${today}T08:00:00+09:00`, title: "送り", code: "dropoff",
    current_assignee_user_id: mama, assignee_user_id: papa, current_label: "ママ", target_label: "パパ",
    expected_revision: 4, expires_at: new Date(Date.now() + 15 * 60_000).toISOString(),
  };
  let preview: Preview | null = null;
  let actor = papa;
  let readError: string | null = null;
  let decideError: string | null = null;
  let message = "";
  let postback: string | null = null;
  let eventTimestamp: number | undefined;
  let transportDate = today;
  let event = 0;
  let initialTurn: Turn | undefined;
  const turns: Turn[] = [];
  const calls: Array<{ rpc: string; args: Record<string, unknown> }> = [];
  const replies: Array<Record<string, unknown>> = [];
  const unexpected: string[] = [];
  const taskQueryDates: Array<string | null> = [];
  const changedPreviewIds = new Set<string>();
  const rpcError = (code: string) => Response.json({ code: "P0001", message: code }, { status: 400 });
  globalThis.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const body = JSON.parse(String((init as { body?: unknown } | undefined)?.body ?? "{}"));
    if (url.hostname === "api.line.me" && url.pathname === "/v2/bot/message/reply") {
      replies.push(body);
      return Promise.resolve(Response.json({}));
    }
    if (url.hostname === "transport-preview-test.supabase.co") {
      const rpc = url.pathname.split("/rpc/")[1];
      if (rpc) {
        calls.push({ rpc, args: body });
        let result: unknown;
        switch (rpc) {
          case "server_tx_claim_webhook_inbox_batch": result = [{ id: `inbox-${event}`, provider_event_id: `event-${event}`,
            source_external_user_id: "test-line-user", attempts: 1, lease_token: "test-lease", payload: {
              type: postback ? "postback" : "message", replyToken: "test-reply",
              ...(eventTimestamp === undefined ? {} : { timestamp: eventTimestamp }),
              ...(postback ? { postback: { data: postback } } : { message: { type: "text", text: message } }),
            } }]; break;
          case "server_tx_resolve_line_actor": result = { user_id: actor, household_id: household }; break;
          case "server_tx_prepare_line_transport_assignment_v1":
            preview = { ...originalPreview, scheduled_date: transportDate, due_at: `${transportDate}T08:00:00+09:00` };
            result = preview; break;
          case "server_read_line_transport_assignment_preview_v1":
            if (readError) return Promise.resolve(rpcError(readError));
            result = preview; break;
          case "server_tx_decide_line_transport_assignment_v1":
            if (decideError) return Promise.resolve(rpcError(decideError));
            if (body.p_actor_id !== papa || body.p_preview_id !== previewId || !preview) return Promise.resolve(rpcError("LINE_TRANSPORT_PREVIEW_NOT_FOUND"));
            if (body.p_action === "confirm_agreed") {
              changedPreviewIds.add(String(body.p_preview_id));
              preview = { ...preview, status: "succeeded", result: { task_id: task, revision: 5 } };
            } else preview = { ...preview, status: "cancelled", result: null };
            result = preview; break;
          case "server_tx_log_line_turn":
            turns.push({ role: body.p_role, text: body.p_text, at: new Date().toISOString(), actor: body.p_actor_id });
            result = { ok: true }; break;
          case "server_read_line_turns": result = turns.filter((turn) => turn.actor === body.p_actor_id).slice(-Number(body.p_limit ?? 4)); break;
          case "server_tx_get_line_conversation_pending":
          case "server_tx_get_line_pending_text_edit": result = null; break;
          case "server_read_line_understand_enabled": result = false; break;
          case "server_tx_get_week_schedule": result = { assignments: [], occurrences: [] }; break;
          case "server_tx_complete_webhook_inbox_item": result = { ok: true }; break;
          default: unexpected.push(rpc); result = null;
        }
        return Promise.resolve(Response.json(result));
      }
      const table = url.pathname.split("/").at(-1);
      if (table === "household_members") return Promise.resolve(Response.json([
        { household_id: household, user_id: papa, family_role: "papa" }, { household_id: household, user_id: mama, family_role: "mama" },
      ]));
      if (table === "task_definitions") return Promise.resolve(Response.json([{ id: definition, household_id: household, code: "dropoff" }]));
      if (table === "task_instances") {
        taskQueryDates.push(url.searchParams.get("scheduled_date"));
        return Promise.resolve(Response.json([{
          id: task, household_id: household, task_definition_id: definition, scheduled_date: transportDate, test_context_id: null,
          planned_assignee_id: mama, status: "todo", revision: 4, due_at: `${transportDate}T08:00:00+09:00`, title: "送り",
        }]));
      }
    }
    unexpected.push(url.hostname + url.pathname);
    return Promise.reject(new Error("Unexpected mocked provider request"));
  };
  const run = async (text: string, button: string | null = null) => {
    message = text;
    postback = button;
    event++;
    calls.length = replies.length = unexpected.length = taskQueryDates.length = 0;
    const response = await handler!(new Request("https://edge.example.com/process-line-inbox", { method: "POST",
      headers: { "Content-Type": "application/json", "X-Family-Ops-Worker-Token": env.CRON_WORKER_TOKEN }, body: "{}" }));
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { claimed: 1, succeeded: 1, failed: 0 });
    assertEquals(unexpected, []);
  };
  const rpcCalls = (rpc: string) => calls.filter((call) => call.rpc === rpc);
  const rendered = () => JSON.stringify(replies);
  const buttonData = (value: unknown = replies): string[] => {
    if (!value || typeof value !== "object") return [];
    return Object.entries(value).flatMap(([key, part]) => key === "data" && typeof part === "string" ? [part] : buttonData(part));
  };
  const assertConfirmation = () => {
    assertStringIncludes(rendered(), "担当変更の確認");
    assertStringIncludes(rendered(), "ママ");
    assertStringIncludes(rendered(), "パパ");
    assertStringIncludes(rendered(), "2人で調整済み");
    assert(buttonData().some((data) => new URLSearchParams(data).get("action") === "lt_agreed_confirm" && new URLSearchParams(data).get("preview_id") === previewId));
  };
  const seed = (overrides: Preview = {}) => {
    preview = { ...originalPreview, ...overrides };
    actor = papa;
    readError = decideError = null;
    turns.splice(0, turns.length, ...(initialTurn ? [{ ...initialTurn }] : []));
  };
  try {
    await import("./index.ts");
    Object.defineProperty(Deno, "serve", originalServe);
    await t.step("a new transport directive prepares the exact task and shows an explicit agreement button without changing it", async () => {
      await run("今日の送りは私に変更してください");
      assertEquals(rpcCalls("server_tx_prepare_line_transport_assignment_v1").length, 1);
      const args = rpcCalls("server_tx_prepare_line_transport_assignment_v1")[0].args;
      assertEquals([args.p_actor_id, args.p_task_id, args.p_assignee_user_id, args.p_expected_revision], [papa, task, papa, 4]);
      assertEquals(typeof args.p_operation_id, "string");
      assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1"), []);
      assertEquals(changedPreviewIds.size, 0);
      assertConfirmation();
      initialTurn = turns.filter((turn) => turn.role === "assistant").at(-1);
      assert(initialTurn);
    });
    await t.step("the user's exact follow-up reopens the same final confirmation and never acts as agreement itself", async () => {
      await run("確認した済みです");
      assertEquals(rpcCalls("server_read_line_transport_assignment_preview_v1").length, 1);
      assertEquals(rpcCalls("server_tx_prepare_line_transport_assignment_v1"), []);
      assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1"), []);
      assertEquals(changedPreviewIds.size, 0);
      assertConfirmation();
    });
    await t.step("only the explicit confirm postback calls the canonical decision with the server preview ID", async () => {
      await run("", `action=lt_agreed_confirm&preview_id=${previewId}`);
      assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1").map((call) => call.args), [{ p_actor_id: papa, p_preview_id: previewId, p_action: "confirm_agreed" }]);
      assertEquals(changedPreviewIds.size, 1);
      assertStringIncludes(rendered(), "変更しました");
    });
    await t.step("redelivering another confirm event uses the same database ID and preserves its successful result", async () => {
      await run("", `action=lt_agreed_confirm&preview_id=${previewId}`);
      assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1").map((call) => call.args), [{ p_actor_id: papa, p_preview_id: previewId, p_action: "confirm_agreed" }]);
      assertEquals(changedPreviewIds.size, 1);
      assertStringIncludes(rendered(), "変更しました");
    });
    await t.step("cancelling a server preview never applies its assignment", async () => {
      seed();
      await run("", `action=lt_cancel&preview_id=${previewId}`);
      assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1").map((call) => call.args), [{ p_actor_id: papa, p_preview_id: previewId, p_action: "cancel" }]);
      assertEquals(changedPreviewIds.size, 1);
      assertStringIncludes(rendered(), "取り消しました");
      assertEquals(rendered().includes("変更しました"), false);
    });
    await t.step("not yet agreed can be followed by agreement reported without losing the same confirmation target", async () => {
      seed();
      await run("まだです");
      assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1"), []);
      assertStringIncludes(rendered(), "担当は変更していません");
      assertEquals(buttonData().some((data) => new URLSearchParams(data).get("action") === "lt_agreed_confirm"), false);
      await run("話し合い済み");
      assertEquals(rpcCalls("server_tx_prepare_line_transport_assignment_v1"), []);
      assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1"), []);
      assertEquals(changedPreviewIds.size, 1);
      assertConfirmation();
    });
    for (const [name, overrides] of [
      ["foreign actor", { actor_id: mama }],
      ["foreign household", { household_id: "30000000-0000-4000-8000-000000000002" }],
      ["expired", { expires_at: new Date(Date.now() - 60_000).toISOString() }],
      ["superseded", { status: "superseded" }],
    ] as const) {
      await t.step(`a ${name} preview cannot be revived by a short agreement report`, async () => {
        seed(overrides);
        await run("確認した済みです");
        assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1"), []);
        assertEquals(buttonData().some((data) => new URLSearchParams(data).get("action") === "lt_agreed_confirm"), false);
        assertEquals(rendered().includes("変更しました"), false);
      });
    }
    for (const kind of ["unknown", "read error"] as const) {
      await t.step(`${kind} preview lookup refuses to invent confirmation or claim success`, async () => {
        seed();
        if (kind === "unknown") preview = null;
        else readError = "INTERNAL_ERROR";
        await run("確認した済みです");
        assertEquals(rpcCalls("server_read_line_transport_assignment_preview_v1").length, 1);
        assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1"), []);
        assertEquals(buttonData().some((data) => new URLSearchParams(data).get("action") === "lt_agreed_confirm"), false);
        assertEquals(rendered().includes("変更しました"), false);
      });
    }
    for (const code of ["LINE_TRANSPORT_PREVIEW_NOT_FOUND", "LINE_TRANSPORT_PREVIEW_EXPIRED", "AGGREGATE_REVISION_CONFLICT"]) {
      await t.step(`canonical ${code} refusal never prints a successful assignment`, async () => {
        seed();
        decideError = code;
        if (code.endsWith("NOT_FOUND")) actor = mama;
        await run("", `action=lt_agreed_confirm&preview_id=${previewId}`);
        assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1").length, 1);
        assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1")[0].args.p_actor_id, actor);
        assertEquals(changedPreviewIds.size, 1);
        assertEquals(rendered().includes("変更しました"), false);
      });
    }
    await t.step("another topic is answered normally and cannot later supply stale agreement context", async () => {
      seed();
      await run("今週");
      assertStringIncludes(rendered(), "今週の予定");
      assertEquals(rpcCalls("server_read_line_transport_assignment_preview_v1"), []);
      assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1"), []);
      await run("確認した済みです");
      assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1"), []);
      assertEquals(buttonData().some((data) => new URLSearchParams(data).get("action") === "lt_agreed_confirm"), false);
    });
    await t.step("a queued message crossing JST midnight keeps the event day's actual task and preview date", async () => {
      seed();
      eventTimestamp = Date.parse(`${today}T00:00:00+09:00`) - 60_000;
      transportDate = new Date(eventTimestamp + 9 * 3600_000).toISOString().slice(0, 10);
      try {
        assert(transportDate !== today);
        await run("今日の送りは私に変更してください");
        assertEquals(taskQueryDates, [`eq.${transportDate}`]);
        const prepare = rpcCalls("server_tx_prepare_line_transport_assignment_v1");
        assertEquals(prepare.length, 1);
        assertEquals([prepare[0].args.p_task_id, prepare[0].args.p_expected_revision], [task, 4]);
        assertEquals(preview?.scheduled_date, transportDate);
        const dayLabel = (date: string) => {
          const day = new Date(`${date}T00:00:00Z`);
          return `${day.getUTCMonth() + 1}/${day.getUTCDate()}(${"日月火水木金土"[day.getUTCDay()]}) 08:00 送り`;
        };
        assertStringIncludes(rendered(), dayLabel(transportDate));
        assertEquals(rendered().includes(dayLabel(today)), false);
        assertEquals(rpcCalls("server_tx_decide_line_transport_assignment_v1"), []);
        assertConfirmation();
      } finally {
        eventTimestamp = undefined;
        transportDate = today;
      }
    });
  } finally {
    Object.defineProperty(Deno, "serve", originalServe);
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) Deno.env.delete(key); else Deno.env.set(key, value);
    }
  }
});
