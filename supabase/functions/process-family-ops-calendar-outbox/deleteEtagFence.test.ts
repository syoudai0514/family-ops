import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  deleteEvent,
  getEvent,
  GoogleCalendarApiError,
} from "../_shared/googleCalendar.ts";

async function assertMissingEtagGetFailsBeforeMutation(eventId: string) {
  const originalFetch = globalThis.fetch;
  let fetchCount = 0;
  let deleteCount = 0;
  globalThis.fetch = ((_input: string | URL | Request, init?: RequestInit) => {
    fetchCount += 1;
    if (init?.method === "DELETE") deleteCount += 1;
    return Promise.resolve(new Response(
      JSON.stringify({ id: eventId }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    ));
  }) as typeof fetch;

  try {
    await assertRejects(
      () => getEvent({ accessToken: "token", calendarId: "calendar", eventId }),
      GoogleCalendarApiError,
      "missing ETag",
    );
    assertEquals(fetchCount, 1);
    assertEquals(deleteCount, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
}

Deno.test("DD8 Task DELETE fails closed on provider GET 200 without ETag before authorization/delete", async () => {
  await assertMissingEtagGetFailsBeforeMutation("task-delete-event");
});

Deno.test("DD8 target deletion fails closed on provider GET 200 without ETag before authorization/delete", async () => {
  await assertMissingEtagGetFailsBeforeMutation("target-delete-event");
});

Deno.test("deleteEvent refuses an empty If-Match without sending a provider request", async () => {
  const originalFetch = globalThis.fetch;
  let fetchCount = 0;
  globalThis.fetch = ((_input: string | URL | Request, _init?: RequestInit) => {
    fetchCount += 1;
    return Promise.resolve(new Response(null, { status: 204 }));
  }) as typeof fetch;

  try {
    await assertRejects(
      () => deleteEvent({
        accessToken: "token",
        calendarId: "calendar",
        eventId: "event-empty-etag",
        ifMatchEtag: "   ",
      }),
      GoogleCalendarApiError,
      "missing If-Match ETag",
    );
    assertEquals(fetchCount, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("deleteEvent always emits the required If-Match header", async () => {
  const originalFetch = globalThis.fetch;
  let observedIfMatch: string | null = null;
  globalThis.fetch = ((_input: string | URL | Request, init?: RequestInit) => {
    observedIfMatch = new Headers(init?.headers).get("If-Match");
    return Promise.resolve(new Response(null, { status: 204 }));
  }) as typeof fetch;

  try {
    const status = await deleteEvent({
      accessToken: "token",
      calendarId: "calendar",
      eventId: "event-with-etag",
      ifMatchEtag: "etag-v7",
    });
    assertEquals(status, 204);
    assertEquals(observedIfMatch, "etag-v7");
  } finally {
    globalThis.fetch = originalFetch;
  }
});
