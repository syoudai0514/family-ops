import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

type Handler = (req: Request) => Promise<Response>;

Deno.test("PWA pending confirmation rejects generic transport cards without changing replay or authorization", async (t) => {
  const env = {
    SUPABASE_URL: "https://confirm-pending.test",
    SUPABASE_SERVICE_ROLE_KEY: "test-service",
    SUPABASE_ANON_KEY: "test-anon",
  };
  const previous = Object.fromEntries(
    Object.keys(env).map((key) => [key, Deno.env.get(key)]),
  );
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  const actorId = "10000000-0000-4000-8000-000000000001";
  const foreignActorId = "10000000-0000-4000-8000-000000000099";
  const pendingId = "20000000-0000-4000-8000-000000000001";
  let invalidJwt = false;
  let mode:
    | "draft"
    | "replay"
    | "foreign"
    | "expired"
    | "read_error"
    | "null_read" = "draft";
  let actionType = "request_create";
  let payload: Record<string, unknown> = {};
  const calls: Array<{ rpc: string; args: Record<string, unknown> }> = [];
  const unexpected: string[] = [];
  let authCalls = 0;
  const originalFetch = globalThis.fetch;
  const originalServe = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  let handler: Handler | undefined;
  Object.defineProperty(Deno, "serve", {
    configurable: true,
    value: (value: Handler) => {
      handler = value;
    },
  });
  globalThis.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.hostname !== "confirm-pending.test") {
      unexpected.push(url.hostname + url.pathname);
      return Promise.reject(new Error("Unexpected external request"));
    }
    if (url.pathname === "/auth/v1/user") {
      authCalls++;
      return Promise.resolve(
        invalidJwt
          ? Response.json({ message: "invalid token", code: "bad_jwt" }, {
            status: 401,
          })
          : Response.json({
            id: actorId,
            aud: "authenticated",
            email: "fixture@example.test",
            role: "authenticated",
          }),
      );
    }
    const rpc = url.pathname.split("/rpc/")[1];
    const args = JSON.parse(
      String((init as { body?: unknown } | undefined)?.body ?? "{}"),
    );
    calls.push({ rpc, args });
    if (rpc === "server_tx_get_pending_action") {
      if (["replay", "foreign", "expired"].includes(mode)) {
        return Promise.resolve(
          Response.json({
            code: "P0001",
            message: "PENDING_ACTION_NOT_EDITABLE",
          }, { status: 400 }),
        );
      }
      if (mode === "read_error") {
        return Promise.resolve(
          Response.json({ code: "P0001", message: "fixture lookup failed" }, {
            status: 500,
          }),
        );
      }
      return Promise.resolve(Response.json(
        mode === "null_read" ? null : {
          id: pendingId,
          status: "draft",
          action_type: actionType,
          normalized_payload: payload,
          revision: 4,
        },
      ));
    }
    if (rpc === "server_tx_confirm_pending_action") {
      if (mode === "foreign") {
        return Promise.resolve(
          Response.json({ code: "P0001", message: "NOT_HOUSEHOLD_MEMBER" }, {
            status: 400,
          }),
        );
      }
      if (mode === "expired") {
        return Promise.resolve(
          Response.json({ code: "P0001", message: "INVALID_INPUT" }, {
            status: 400,
          }),
        );
      }
      return Promise.resolve(
        Response.json({
          pending_action_id: pendingId,
          status: mode === "replay" ? "succeeded" : "confirmed",
        }),
      );
    }
    unexpected.push(url.pathname);
    return Promise.reject(new Error("Unexpected database request"));
  };
  const run = async (
    body: Record<string, unknown> = { pending_action_id: pendingId },
    auth = true,
  ) => {
    calls.length = unexpected.length = 0;
    authCalls = 0;
    const response = await handler!(
      new Request("https://edge.example/confirm-pending-action", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(auth ? { Authorization: "Bearer fixture-jwt" } : {}),
        },
        body: JSON.stringify(body),
      }),
    );
    const data = await response.json();
    assertEquals(unexpected, []);
    return { response, data };
  };
  const confirms = () =>
    calls.filter(({ rpc }) => rpc === "server_tx_confirm_pending_action");
  try {
    await import("./index.ts");
    Object.defineProperty(Deno, "serve", originalServe);
    await t.step(
      "missing and invalid JWTs reject before a pending or confirm lookup",
      async () => {
        let result = await run(undefined, false);
        assertEquals(result.response.status, 401);
        assertEquals(calls, []);
        assertEquals(authCalls, 0);
        invalidJwt = true;
        result = await run();
        assertEquals(result.response.status, 401);
        assertEquals(calls, []);
        assertEquals(authCalls, 1);
        invalidJwt = false;
      },
    );
    await t.step(
      "old generic requests preserve the stored occurrence date and cannot confirm",
      async () => {
        for (
          const raw_text of [
            "明日の送りは私に変更してください",
            "妻と話し合い済みです。明日の送りは私に変更してください",
          ]
        ) {
          payload = {
            raw_text,
            title: "明日の送り担当をパパに変更",
            scheduled_date: "2026-10-15",
          };
          const { response, data } = await run({
            pending_action_id: pendingId,
            actor_id: foreignActorId,
            already_agreed: true,
          });
          assertEquals(response.status, 400);
          assertEquals(data.error.code, "INVALID_INPUT");
          assertStringIncludes(data.error.message, "2026-10-15の送り");
          assertStringIncludes(data.error.message, "担当を調整");
          assertStringIncludes(
            data.error.message,
            "送信・担当変更はしていません",
          );
          assertEquals(confirms(), []);
          assertEquals(calls[0].args, {
            p_actor_id: actorId,
            p_pending_action_id: pendingId,
          });
        }
      },
    );
    await t.step(
      "old generic task cards are blocked with a title fallback, without assigning a default date",
      async () => {
        actionType = "task_create_once";
        payload = {
          raw_text: " ",
          title: "明日のお迎えをママに変更して",
          scheduled_date: "2026-02-30",
        };
        const { response, data } = await run();
        assertEquals(response.status, 400);
        assertStringIncludes(data.error.message, "対象日のお迎え");
        assertEquals(data.error.message.includes("2026-02-30"), false);
        assertEquals(confirms(), []);
      },
    );
    await t.step(
      "ordinary requests use the original authenticated confirmation RPC",
      async () => {
        actionType = "request_create";
        payload = {
          raw_text: "明日牛乳を買って",
          title: "牛乳を買う",
          scheduled_date: "2026-10-15",
        };
        const { response, data } = await run();
        assertEquals(response.status, 200);
        assertEquals(data, {
          pending_action_id: pendingId,
          status: "confirmed",
        });
        assertEquals(confirms(), [{
          rpc: "server_tx_confirm_pending_action",
          args: { p_actor_id: actorId, p_pending_action_id: pendingId },
        }]);
      },
    );
    await t.step(
      "the original raw text takes priority over a misleading title and canonical assignment requests stay valid",
      async () => {
        payload = {
          raw_text: "送りの変更についてママに話すメモを作る",
          title: "明日の送りをママに変更して",
        };
        assertEquals((await run()).response.status, 200);
        assertEquals(confirms().length, 1);
        actionType = "assignment_change_request";
        payload = { raw_text: "明日のお迎えをママにお願い" };
        assertEquals((await run()).response.status, 200);
        assertEquals(confirms().length, 1);
      },
    );
    await t.step(
      "a successful confirmation replay remains a success no-op through the canonical RPC",
      async () => {
        mode = "replay";
        const { response, data } = await run();
        assertEquals(response.status, 200);
        assertEquals(data, {
          pending_action_id: pendingId,
          status: "succeeded",
        });
        assertEquals(confirms().length, 1);
      },
    );
    await t.step(
      "another actor's card and expired cards retain canonical refusal",
      async () => {
        mode = "foreign";
        let result = await run({
          pending_action_id: pendingId,
          actor_id: foreignActorId,
        });
        assertEquals(result.response.status, 403);
        assertEquals(result.data.error.code, "NOT_HOUSEHOLD_MEMBER");
        assertEquals(confirms()[0].args.p_actor_id, actorId);
        mode = "expired";
        result = await run();
        assertEquals(result.response.status, 400);
        assertEquals(result.data.error.code, "INVALID_INPUT");
      },
    );
    await t.step(
      "unknown read failures and missing readbacks never continue to confirm",
      async () => {
        for (const nextMode of ["read_error", "null_read"] as const) {
          mode = nextMode;
          const { response, data } = await run();
          assertEquals(response.status, 500);
          assertStringIncludes(data.error.message, "送信していません");
          assertEquals(confirms(), []);
        }
      },
    );
  } finally {
    Object.defineProperty(Deno, "serve", originalServe);
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
});
