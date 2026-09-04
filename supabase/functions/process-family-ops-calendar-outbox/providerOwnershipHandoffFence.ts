import { getEvent, patchEvent } from "../_shared/googleCalendar.ts";

type ProviderEventRead = Awaited<ReturnType<typeof getEvent>>;
type ProviderEventPatch = Awaited<ReturnType<typeof patchEvent>>;

type HandoffDeps = {
  get: (args: Parameters<typeof getEvent>[0]) => Promise<ProviderEventRead>;
  patch: (args: Parameters<typeof patchEvent>[0]) => Promise<ProviderEventPatch>;
};

export class ProviderOwnershipHandoffError extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "ProviderOwnershipHandoffError";
  }
}

export interface ProviderOwnershipHandoffEvidence {
  ifMatchEtag: string;
  providerEtag: string;
  providerSnapshot: Record<string, unknown>;
}

/**
 * Establishes the provider-side half of a Task/target-deletion -> Family Event
 * ownership transfer after a previous provider mutation became uncertain.
 *
 * Correctness does not depend on waiting N seconds for an old HTTP request to
 * disappear. Instead we conditionally PATCH a unique handoff token onto the
 * exact Google event. A successful PATCH advances Google's ETag. Any older
 * PATCH/DELETE still in flight carries an older If-Match value and therefore
 * cannot succeed after this barrier. If the older request wins the race first,
 * our PATCH receives 412 and we re-GET/retry against the new ETag. A stale
 * deterministic INSERT cannot overwrite an event id that now exists.
 *
 * Nothing calls this helper from a production Family Event writer yet: that
 * capability remains R0/fail-closed. The DB transfer RPC requires evidence
 * produced by this protocol before it will consume an uncertain mutation.
 */
export async function establishProviderOwnershipHandoffFence(
  args: {
    accessToken: string;
    calendarId: string;
    eventId: string;
    handoffToken: string;
    maxAttempts?: number;
  },
  deps: HandoffDeps = { get: getEvent, patch: patchEvent },
): Promise<ProviderOwnershipHandoffEvidence> {
  const maxAttempts = Math.max(1, Math.min(args.maxAttempts ?? 4, 8));

  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const before = await deps.get({
      accessToken: args.accessToken,
      calendarId: args.calendarId,
      eventId: args.eventId,
    });
    if (before.status === 404 || !before.body) {
      throw new ProviderOwnershipHandoffError("PROVIDER_HANDOFF_EVENT_NOT_FOUND");
    }
    if (!before.etag) {
      throw new ProviderOwnershipHandoffError("PROVIDER_HANDOFF_ETAG_MISSING");
    }

    const currentExtended =
      before.body.extendedProperties && typeof before.body.extendedProperties === "object"
        ? before.body.extendedProperties as Record<string, unknown>
        : {};
    const currentPrivate =
      currentExtended.private && typeof currentExtended.private === "object"
        ? currentExtended.private as Record<string, unknown>
        : {};

    const patch = await deps.patch({
      accessToken: args.accessToken,
      calendarId: args.calendarId,
      eventId: args.eventId,
      ifMatchEtag: before.etag,
      body: {
        extendedProperties: {
          ...currentExtended,
          private: {
            ...currentPrivate,
            familyOpsOwnershipFenceToken: args.handoffToken,
          },
        },
      },
    });

    if (patch.status === 412) continue;
    if (patch.status < 200 || patch.status >= 300) {
      throw new ProviderOwnershipHandoffError(`PROVIDER_HANDOFF_PATCH_${patch.status}`);
    }

    // Re-GET after the conditional PATCH and confirm both the token and the ETag
    // transition before returning evidence to the DB confirmation RPC.
    const after = await deps.get({
      accessToken: args.accessToken,
      calendarId: args.calendarId,
      eventId: args.eventId,
    });
    if (after.status !== 200 || !after.body || !after.etag) {
      throw new ProviderOwnershipHandoffError("PROVIDER_HANDOFF_CONFIRMATION_READ_FAILED");
    }
    const token = (
      after.body.extendedProperties as { private?: Record<string, unknown> } | undefined
    )?.private?.familyOpsOwnershipFenceToken;
    if (token !== args.handoffToken) {
      throw new ProviderOwnershipHandoffError("PROVIDER_HANDOFF_TOKEN_MISMATCH");
    }
    if (after.etag === before.etag) {
      throw new ProviderOwnershipHandoffError("PROVIDER_HANDOFF_ETAG_NOT_ADVANCED");
    }

    return {
      ifMatchEtag: before.etag,
      providerEtag: after.etag,
      providerSnapshot: after.body,
    };
  }

  throw new ProviderOwnershipHandoffError("PROVIDER_HANDOFF_ETAG_CONFLICT_RETRY_EXHAUSTED");
}
