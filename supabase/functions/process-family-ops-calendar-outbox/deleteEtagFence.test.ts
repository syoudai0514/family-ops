import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  deleteEvent,
  getEvent,
  GoogleCalendarApiError,
} from "../_shared/googleCalendar.ts";
import { deleteExistingEventWithFence } from "./conditionalDeleteWorkflow.ts";

async function assertMissingEtagWorkflowFailsBeforeAuthorizationAndDelete(eventId: string) {
  const originalFetch = globalThis.fetch;
  let fetchCount = 0;
  let providerDeleteCount = 0;
  let authorizeCount = 0;
  let deleteWorkflowCount = 0;

  globalThis.fetch = ((_input: string | URL | Request, init?: RequestInit) => {
    fetchCount += 1;
    if (init?.method === "DELETE") providerDeleteCount += 1;
    return Promise.resolve(new Response(
      JSON.stringify({ id: eventId }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    ));
  }) as typeof fetch;

  try {
    await assertRejects(
      () => deleteExistingEventWithFence({
        readEvent: () => getEvent({ accessToken: "token", calendarId: "calendar", eventId }),
        authorize: () => {
          authorizeCount += 1;
          return Promise.resolve({
            authorized: true,
            request_deadline_at: new Date(Date.now() + 5_000).toISOString(),
          });
        },
        deleteWithEtag: async (etag) => {
          deleteWorkflowCount += 1;
          return await deleteEvent({
            accessToken: "token",
            calendarId: "calendar",
            eventId,
            ifMatchEtag: etag,
          });
        },
      }),
      GoogleCalendarApiError,
      "missing ETag",
    );
    assertEquals(fetchCount, 1);
    assertEquals(authorizeCount, 0);
    assertEquals(deleteWorkflowCount, 0);
    assertEquals(providerDeleteCount, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
}

Deno.test("DD8 Task DELETE fails closed on provider GET 200 without ETag before DB authorization/delete", async () => {
  await assertMissingEtagWorkflowFailsBeforeAuthorizationAndDelete("task-delete-event");
});

Deno.test("DD8 target deletion fails closed on provider GET 200 without ETag before DB authorization/delete", async () => {
  await assertMissingEtagWorkflowFailsBeforeAuthorizationAndDelete("target-delete-event");
});

Deno.test("shared DELETE workflow re-reads and re-authorizes a 412 retry", async () => {
  let readCount = 0;
  let authorizeCount = 0;
  let deleteCount = 0;
  const seenEtags: string[] = [];

  const status = await deleteExistingEventWithFence({
    readEvent: () => {
      readCount += 1;
      return Promise.resolve({ status: 200 as const, etag: readCount === 1 ? "etag-v1" : "etag-v2" });
    },
    authorize: () => {
      authorizeCount += 1;
      return Promise.resolve({
        authorized: true,
        request_deadline_at: new Date(Date.now() + 5_000).toISOString(),
      });
    },
    deleteWithEtag: (etag) => {
      deleteCount += 1;
      seenEtags.push(etag);
      return Promise.resolve(deleteCount === 1 ? 412 : 204);
    },
  });

  assertEquals(status, 204);
  assertEquals(readCount, 2);
  assertEquals(authorizeCount, 2);
  assertEquals(deleteCount, 2);
  assertEquals(seenEtags, ["etag-v1", "etag-v2"]);
});

Deno.test("shared DELETE workflow does not authorize or mutate a missing provider event", async () => {
  let authorizeCount = 0;
  let deleteCount = 0;
  const status = await deleteExistingEventWithFence({
    readEvent: () => Promise.resolve({ status: 404 as const, etag: null }),
    authorize: () => {
      authorizeCount += 1;
      return Promise.resolve({
        authorized: true,
        request_deadline_at: new Date(Date.now() + 5_000).toISOString(),
      });
    },
    deleteWithEtag: () => {
      deleteCount += 1;
      return Promise.resolve(204);
    },
  });
  assertEquals(status, 404);
  assertEquals(authorizeCount, 0);
  assertEquals(deleteCount, 0);
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
