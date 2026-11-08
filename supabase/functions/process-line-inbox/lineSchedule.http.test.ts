import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

type Json = Record<string, unknown>;
type Handler = (req: Request) => Promise<Response>;

function postbacks(value: unknown): Array<{ label: string; data: string }> {
  if (!value || typeof value !== "object") return [];
  if (Array.isArray(value)) return value.flatMap(postbacks);
  const item = value as Json;
  return [...(item.type === "postback" && typeof item.data === "string" ? [{ label: String(item.label), data: item.data }] : []), ...Object.values(item).flatMap(postbacks)];
}

// Real worker entry → canonical read RPC → real Reply payload → next postback.
// All HTTP is intercepted; this never calls a deployed project or LINE account.
Deno.test("LINE worker keeps schedule continuation scoped to original dates and fresh actor", async (t) => {
  const env = {
    SUPABASE_URL: "https://schedule-http-test.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "test-service", CRON_WORKER_TOKEN: "schedule-http-worker",
    LINE_CHANNEL_ACCESS_TOKEN: "test-line", APP_BASE_URL: "https://family-test.example.com",
  };
  const oldEnv = Object.fromEntries(Object.keys(env).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  const originalFetch = globalThis.fetch;
  const originalServe = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  let handler: Handler | undefined;
  Object.defineProperty(Deno, "serve", { configurable: true, value: (value: Handler) => { handler = value; } });
  let event = 0;
  let data = "";
  let actor = "20000000-0000-4000-8000-000000000001";
  let household = "30000000-0000-4000-8000-000000000001";
  let count = 14;
  let readError = false;
  const calls: Array<{ rpc: string; args: Json }> = [];
  const scopes: string[] = [];
  const replies: Json[] = [];
  const unexpected: string[] = [];
  globalThis.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const body = JSON.parse(String(init?.body ?? "{}")) as Json;
    if (url.hostname === "api.line.me" && url.pathname === "/v2/bot/message/reply") {
      replies.push(body);
      return Promise.resolve(Response.json({}));
    }
    if (url.hostname === "schedule-http-test.supabase.co") {
      const rpc = url.pathname.split("/rpc/")[1];
      if (rpc) {
        calls.push({ rpc, args: body });
        switch (rpc) {
          case "server_tx_claim_webhook_inbox_batch": return Promise.resolve(Response.json([{
            id: `inbox-${event}`, provider_event_id: `event-${event}`, source_external_user_id: "test-line-user", attempts: 1, lease_token: "lease", payload: {
              type: "postback", replyToken: `reply-${event}`, postback: { data },
            },
          }]));
          case "server_tx_resolve_line_actor": return Promise.resolve(Response.json({ user_id: actor, household_id: household }));
          case "server_tx_line_request_context":
          case "server_tx_log_line_turn": return Promise.resolve(Response.json(null));
          case "server_tx_complete_webhook_inbox_item": return Promise.resolve(Response.json({ ok: true }));
          case "server_tx_get_week_schedule":
            if (readError) return Promise.resolve(Response.json({ message: "SCHEDULE_READ_FAILED", code: "P0001" }, { status: 400 }));
            return Promise.resolve(Response.json({ assignments: Array.from({ length: count }, (_, i) => ({
              task_instance_id: `task-${i}`, title: `予定${String(i + 1).padStart(2, "0")}`,
              due_at: `2026-11-08T${String(i + 1).padStart(2, "0")}:00:00+09:00`, planned_assignee_id: actor,
            })), occurrences: [] }));
          default: unexpected.push(rpc); return Promise.resolve(Response.json(null));
        }
      }
      if (url.pathname.endsWith("/household_members")) {
        scopes.push(url.searchParams.get("household_id") ?? "");
        return Promise.resolve(Response.json([{ user_id: actor, family_role: "papa" }]));
      }
    }
    unexpected.push(url.hostname + url.pathname);
    return Promise.reject(new Error("Unexpected mocked HTTP"));
  };
  const run = async (button: string) => {
    data = button;
    event++;
    calls.length = scopes.length = replies.length = unexpected.length = 0;
    const response = await handler!(new Request("https://edge.example.com/process-line-inbox", {
      method: "POST", headers: { "Content-Type": "application/json", "X-Family-Ops-Worker-Token": env.CRON_WORKER_TOKEN }, body: "{}",
    }));
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { claimed: 1, succeeded: 1, failed: 0 });
    assertEquals(unexpected, []);
  };
  const rendered = () => JSON.stringify(replies);
  const scheduleCalls = () => calls.filter((call) => call.rpc === "server_tx_get_week_schedule");
  try {
    await import("./index.ts");
    Object.defineProperty(Deno, "serve", originalServe);
    let next = "";
    await t.step("first page exposes continuation without requiring PWA", async () => {
      await run("action=schedule_page&start=2026-11-08&end=2026-11-08&page=0");
      assertStringIncludes(rendered(), "予定06");
      assert(!rendered().includes("予定07"));
      const button = postbacks(replies).find((item) => item.label === "続きの予定");
      assert(button);
      next = button.data;
      assertEquals(Object.fromEntries(new URLSearchParams(next)), { action: "schedule_page", start: "2026-11-08", end: "2026-11-08", page: "1" });
      assertStringIncludes(rendered(), "/month?date=2026-11-08");
    });
    await t.step("next page rereads the same original day", async () => {
      await run(next);
      assertStringIncludes(rendered(), "予定07");
      assertStringIncludes(rendered(), "予定12");
      assert(!rendered().includes("予定06"));
      assertEquals(scheduleCalls()[0].args, { p_actor_id: actor, p_start_date: "2026-11-08", p_end_date: "2026-11-08" });
    });
    await t.step("a later view uses new rows and clamps a vanished page", async () => {
      count = 1;
      await run(next);
      assertStringIncludes(rendered(), "予定01");
      assert(!rendered().includes("予定07"));
      assertStringIncludes(rendered(), "1/1ページ");
    });
    await t.step("old postback cannot override the currently resolved actor or household", async () => {
      actor = "20000000-0000-4000-8000-000000000002";
      household = "30000000-0000-4000-8000-000000000002";
      await run(`${next}&actor_id=old-user&household_id=old-family`);
      assertEquals(scheduleCalls()[0].args.p_actor_id, actor);
      assertEquals(scopes, [`eq.${household}`]);
    });
    await t.step("invalid dates and oversized range are rejected before schedule read", async () => {
      for (const button of ["action=schedule_page&start=2026-02-30&end=2026-02-30&page=0", "action=schedule_page&start=2026-11-08&end=2026-11-15&page=0"]) {
        await run(button);
        assertEquals(scheduleCalls(), []);
        assertStringIncludes(rendered(), "この予定一覧は開けません");
      }
    });
    await t.step("failed read explains retry and never announces an empty calendar", async () => {
      readError = true;
      await run(next);
      assert(!rendered().includes("予定はありません"));
      assertStringIncludes(rendered(), "読み込めません");
    });
  } finally {
    Object.defineProperty(Deno, "serve", originalServe);
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(oldEnv)) {
      if (value === undefined) Deno.env.delete(key); else Deno.env.set(key, value);
    }
  }
});
