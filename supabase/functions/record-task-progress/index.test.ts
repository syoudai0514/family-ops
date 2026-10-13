import { assertEquals } from "jsr:@std/assert@1";

type Handler = (req: Request) => Promise<Response>;

Deno.test("task progress endpoint authenticates first and forwards only bounded self records", async (t) => {
  const originalServe = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  let handler: Handler | undefined;
  Object.defineProperty(Deno, "serve", { configurable: true, value: (value: Handler) => { handler = value; } });
  try { await import("./index.ts"); }
  finally { Object.defineProperty(Deno, "serve", originalServe); }
  const endpoint = handler!;
  const env = { SUPABASE_URL: "https://progress-test.supabase.co", SUPABASE_ANON_KEY: "test-anon", SUPABASE_SERVICE_ROLE_KEY: "test-service" };
  const previous = Object.fromEntries(Object.keys(env).map(key => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  const originalFetch = globalThis.fetch;
  let args: Record<string, unknown> | undefined;
  let calls = 0;
  let rpcError: string | null = null;
  globalThis.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.pathname === "/auth/v1/user") return Promise.resolve(Response.json({ id: "20000000-0000-4000-8000-000000000001" }));
    if (url.pathname.endsWith("/server_tx_record_task_progress")) {
      calls++;
      args = JSON.parse(String((init as { body?: unknown } | undefined)?.body));
      return Promise.resolve(rpcError
        ? Response.json({ message: rpcError, code: "P0001" }, { status: 400 })
        : Response.json({ task_id: args?.p_task_id, task_event_id: "event", revision: 5, handover_id: null }));
    }
    throw new Error(`Unexpected fetch: ${url.pathname}`);
  };
  const body = { operation_id: "10000000-0000-4000-8000-000000000001", task_id: "30000000-0000-4000-8000-000000000001", expected_revision: 4,
    observed_note: " 昨日の分が未洗浄だった ", work_done_note: "朝の食器を追加して洗浄開始", remaining_note: "洗浄中", next_step_note: "終了後に取り出し",
    share_with_household: false, ack_policy: "none" };
  const request = (value: unknown = body, authenticated = true) => new Request("https://edge.example.com", {
    method: "POST", headers: { ...(authenticated ? { Authorization: "Bearer test-user" } : {}), "Content-Type": "application/json" }, body: JSON.stringify(value),
  });
  try {
    await t.step("unauthenticated requests never reach a service-role RPC", async () => {
      assertEquals((await endpoint(request(body, false))).status, 401);
      assertEquals(calls, 0);
    });
    await t.step("notes, revisions and share controls reject invalid payloads before RPC", async () => {
      for (const invalid of [
        { ...body, task_id: "foreign-looking-id" }, { ...body, operation_id: "bad" },
        { ...body, expected_revision: null }, { ...body, expected_revision: 0 },
        { ...body, expected_revision: 1.5 }, { ...body, share_with_household: "yes" },
        { ...body, observed_note: 123 }, { ...body, work_done_note: "a".repeat(2001) },
        { ...body, observed_note: "\n\t　", work_done_note: "", remaining_note: null, next_step_note: null },
        { ...body, ack_policy: "required" }, { ...body, valid_until: "tomorrow" },
        { ...body, share_with_household: true, valid_until: "2026-12-01" },
        { ...body, share_with_household: true, valid_until: "2026-02-30T10:00:00+09:00" },
        { ...body, share_with_household: true, valid_until: "2026-12-01T24:00:00+09:00" },
      ]) assertEquals((await endpoint(request(invalid))).status, 400);
      assertEquals(calls, 0);
    });
    await t.step("a supplied actor or performer cannot impersonate the household partner", async () => {
      const response = await endpoint(request({ ...body, actor_id: "partner", performer_actor_ref_id: "partner", completed: true }));
      assertEquals(response.status, 200);
      assertEquals(args, {
        p_actor_id: "20000000-0000-4000-8000-000000000001", p_operation_id: body.operation_id,
        p_task_id: body.task_id, p_expected_revision: 4, p_observed_note: "昨日の分が未洗浄だった",
        p_work_done_note: body.work_done_note, p_remaining_note: body.remaining_note, p_next_step_note: body.next_step_note,
        p_share_with_household: false, p_ack_policy: "none", p_valid_until: null,
      });
      assertEquals((await response.json()).revision, 5);
    });
    await t.step("CAS conflict is a definite refusal with its standard 409 code", async () => {
      rpcError = "AGGREGATE_REVISION_CONFLICT";
      const response = await endpoint(request());
      assertEquals(response.status, 409);
      assertEquals((await response.json()).error.code, "AGGREGATE_REVISION_CONFLICT");
    });
    await t.step("explicit sharing keeps acknowledgement and exact expiry in one command", async () => {
      rpcError = null;
      const expiry = "2026-12-01T10:00:00+09:00";
      assertEquals((await endpoint(request({ ...body, share_with_household: true, ack_policy: "required", valid_until: expiry }))).status, 200);
      assertEquals(args?.p_share_with_household, true);
      assertEquals(args?.p_ack_policy, "required");
      assertEquals(args?.p_valid_until, expiry);
    });
  } finally {
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) Deno.env.delete(key); else Deno.env.set(key, value);
    }
  }
});
