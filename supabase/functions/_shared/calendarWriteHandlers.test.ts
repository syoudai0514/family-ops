import { assertEquals } from "jsr:@std/assert@1";
import { encryptRefreshToken } from "./cryptoHelper.ts";

type Handler = (req: Request) => Promise<Response>;

// Exercise the real entrypoints with an in-memory RPC ledger and provider.
// Capturing serve avoids opening a listener; every fetch is intercepted.
Deno.test("calendar writes preserve retryable receipts and reconcile complete provider identity", async (t) => {
  const originalServe = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  const handlers: Handler[] = [];
  Object.defineProperty(Deno, "serve", { configurable: true, value: (handler: Handler) => { handlers.push(handler); } });
  try {
    await import("../create-calendar-event/index.ts");
    await import("../update-calendar-event/index.ts");
  } finally {
    Object.defineProperty(Deno, "serve", originalServe);
  }
  assertEquals(handlers.length, 2);
  const [create, update] = handlers;

  const env = {
    SUPABASE_URL: "https://calendar-write-test.supabase.co",
    SUPABASE_ANON_KEY: "test-anon-key",
    SUPABASE_SERVICE_ROLE_KEY: "test-service-key",
    GOOGLE_CALENDAR_CLIENT_ID: "test-google-client",
    GOOGLE_CALENDAR_CLIENT_SECRET: "test-google-secret",
    GOOGLE_TOKEN_ENCRYPTION_KEY: btoa(String.fromCharCode(...new Uint8Array(32))),
  };
  const previous = Object.fromEntries(Object.keys(env).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  const originalFetch = globalThis.fetch;
  try {
    const encrypted = await encryptRefreshToken("test-refresh-token");
    const operationId = "10000000-0000-4000-8000-000000000001";
    const eventId = "fo10000000000040008000000000000001";
    const timed = { start_date_time: "2026-10-24T09:00:00+09:00", end_date_time: "2026-10-24T10:00:00+09:00" };
    const remote = { id: eventId, etag: '"remote-etag"', start: { dateTime: timed.start_date_time }, end: { dateTime: timed.end_date_time } };
    let status = "pending";
    let writes = 0;
    let writeResult: () => Response = () => Response.json({ etag: '"written-etag"' });
    let getResult: () => Record<string, unknown> = () => remote;
    globalThis.fetch = (input, init) => {
      const options = init as { method?: string; body?: unknown } | undefined;
      const url = new URL(input instanceof Request ? input.url : String(input));
      const method = options?.method ?? (input instanceof Request ? input.method : "GET");
      if (url.pathname === "/auth/v1/user") return Promise.resolve(Response.json({ id: "20000000-0000-4000-8000-000000000001" }));
      if (url.pathname.endsWith("/server_tx_claim_google_write")) {
        return Promise.resolve(Response.json({ google_event_id: eventId, status, result_etag: null }));
      }
      if (url.pathname.endsWith("/server_tx_finalize_google_write")) {
        status = JSON.parse(String(options?.body)).p_status;
        return Promise.resolve(Response.json({ status }));
      }
      if (url.pathname.endsWith("/server_tx_get_google_sync_context")) {
        return Promise.resolve(Response.json({ external_calendar_id: "family@example.com", household_id: "household", encrypted_refresh_token: encrypted.ciphertext, encryption_version: encrypted.encryptionVersion }));
      }
      if (url.pathname.endsWith("/server_tx_enqueue_google_sync")) return Promise.resolve(Response.json({ enqueued: true }));
      if (url.href === "https://oauth2.googleapis.com/token") return Promise.resolve(Response.json({ access_token: "test-access-token", expires_in: 3600 }));
      if (url.hostname === "www.googleapis.com" && url.pathname.includes("/events")) {
        if (method === "GET") return Promise.resolve(Response.json(getResult()));
        writes++;
        return Promise.resolve(writeResult());
      }
      throw new Error(`Unexpected fetch: ${method} ${url}`);
    };
    const request = () => new Request("https://edge.example.com", {
      method: "POST", headers: { Authorization: "Bearer test-user-token", "Content-Type": "application/json" },
      body: JSON.stringify({ operation_id: operationId, calendar_connection_id: "connection", google_event_id: eventId, title: "Appointment", ...timed }),
    });

    for (const [name, handler] of [["create", create], ["update", update]] as const) {
      await t.step(`${name}: provider 503 stays pending and the same operation succeeds on retry`, async () => {
        status = "pending";
        writes = 0;
        writeResult = () => Response.json({ error: "temporarily unavailable" }, { status: 503 });
        assertEquals((await handler(request())).status, 503);
        assertEquals(status, "pending");
        writeResult = () => Response.json({ etag: '"written-etag"' }, { status: name === "create" ? 201 : 200 });
        assertEquals((await handler(request())).status, 200);
        assertEquals(status, "succeeded");
        assertEquals(writes, 2);
      });
    }
    await t.step("create: lost response with a different operation marker cannot succeed", async () => {
      status = "pending";
      writeResult = () => { throw new TypeError("response lost"); };
      getResult = () => ({ ...remote, extendedProperties: { private: { familyOpsOperationId: "other-operation" } } });
      assertEquals((await create(request())).status, 503);
      assertEquals(status, "pending");
    });
    await t.step("update: lost response with an unchanged start but different end cannot succeed", async () => {
      status = "pending";
      getResult = () => ({ ...remote, summary: "Appointment", end: { dateTime: "2026-10-24T11:00:00+09:00" } });
      assertEquals((await update(request())).status, 503);
      assertEquals(status, "pending");
    });
    await t.step("update: an ETag conflict with a different end remains a conflict", async () => {
      status = "pending";
      writeResult = () => Response.json({ error: "condition failed" }, { status: 412 });
      assertEquals((await update(request())).status, 409);
      assertEquals(status, "conflict");
    });
  } finally {
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
});
