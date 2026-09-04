import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  establishProviderOwnershipHandoffFence,
  ProviderOwnershipHandoffError,
} from "./providerOwnershipHandoffFence.ts";

Deno.test("provider handoff retries after stale request wins 412 race and returns advanced ETag evidence", async () => {
  const handoffToken = crypto.randomUUID();
  let getCount = 0;
  let patchCount = 0;
  const patchEtags: string[] = [];

  const evidence = await establishProviderOwnershipHandoffFence(
    {
      accessToken: "token",
      calendarId: "calendar",
      eventId: "event-1",
      handoffToken,
      maxAttempts: 4,
    },
    {
      get: () => {
        getCount += 1;
        if (getCount === 1) {
          return Promise.resolve({ status: 200, etag: "v1", body: { id: "event-1" } });
        }
        if (getCount === 2) {
          // The old in-flight provider mutation won before our first barrier
          // PATCH, so the re-read observes its newer ETag.
          return Promise.resolve({ status: 200, etag: "v2", body: { id: "event-1" } });
        }
        return Promise.resolve({
          status: 200,
          etag: "v3",
          body: {
            id: "event-1",
            extendedProperties: {
              private: { familyOpsOwnershipFenceToken: handoffToken },
            },
          },
        });
      },
      patch: (args) => {
        patchCount += 1;
        patchEtags.push(args.ifMatchEtag);
        if (patchCount === 1) return Promise.resolve({ status: 412, body: null });
        const privateProps = (args.body.extendedProperties as { private?: Record<string, unknown> } | undefined)?.private;
        assertEquals(privateProps?.familyOpsOwnershipFenceToken, handoffToken);
        return Promise.resolve({ status: 200, body: { etag: "v3" } });
      },
    },
  );

  assertEquals(patchCount, 2);
  assertEquals(patchEtags, ["v1", "v2"]);
  assertEquals(evidence.ifMatchEtag, "v2");
  assertEquals(evidence.providerEtag, "v3");
  assertEquals(
    (evidence.providerSnapshot.extendedProperties as { private?: Record<string, unknown> } | undefined)
      ?.private?.familyOpsOwnershipFenceToken,
    handoffToken,
  );
});

Deno.test("provider handoff fails closed when confirmation read loses the handoff token", async () => {
  const handoffToken = crypto.randomUUID();
  let getCount = 0;

  await assertRejects(
    () => establishProviderOwnershipHandoffFence(
      {
        accessToken: "token",
        calendarId: "calendar",
        eventId: "event-2",
        handoffToken,
      },
      {
        get: () => {
          getCount += 1;
          if (getCount === 1) return Promise.resolve({ status: 200, etag: "v1", body: { id: "event-2" } });
          return Promise.resolve({ status: 200, etag: "v2", body: { id: "event-2" } });
        },
        patch: () => Promise.resolve({ status: 200, body: { etag: "v2" } }),
      },
    ),
    ProviderOwnershipHandoffError,
    "PROVIDER_HANDOFF_TOKEN_MISMATCH",
  );
});

Deno.test("provider handoff fails closed when provider ETag does not advance", async () => {
  const handoffToken = crypto.randomUUID();
  let getCount = 0;

  await assertRejects(
    () => establishProviderOwnershipHandoffFence(
      {
        accessToken: "token",
        calendarId: "calendar",
        eventId: "event-3",
        handoffToken,
      },
      {
        get: () => {
          getCount += 1;
          return Promise.resolve({
            status: 200,
            etag: "v1",
            body: getCount === 1
              ? { id: "event-3" }
              : {
                id: "event-3",
                extendedProperties: {
                  private: { familyOpsOwnershipFenceToken: handoffToken },
                },
              },
          });
        },
        patch: () => Promise.resolve({ status: 200, body: { etag: "v1" } }),
      },
    ),
    ProviderOwnershipHandoffError,
    "PROVIDER_HANDOFF_ETAG_NOT_ADVANCED",
  );
});
