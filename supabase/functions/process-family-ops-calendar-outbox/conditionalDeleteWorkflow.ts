import type { ProviderMutationAuthorization } from "./providerMutationFence.ts";
import { withProviderMutationFence } from "./providerMutationFence.ts";

type ExistingEvent =
  | { status: 404; etag: null }
  | { status: 200; etag: string };

/**
 * Shared DELETE workflow for both Task mirrors and stale target cleanup.
 *
 * `readEvent` must itself fail closed when a provider returns HTTP 200 without
 * a usable ETag. Because it is awaited before `authorize`, such an abnormal
 * response cannot establish a DB provider-mutation authorization and cannot
 * invoke DELETE. Every 412 retry performs a fresh read and a fresh authorization.
 */
export async function deleteExistingEventWithFence(deps: {
  readEvent: () => Promise<ExistingEvent>;
  authorize: () => Promise<ProviderMutationAuthorization>;
  deleteWithEtag: (etag: string) => Promise<number>;
}): Promise<number> {
  const existing = await deps.readEvent();
  if (existing.status !== 200) return existing.status;

  let status = await withProviderMutationFence(
    deps.authorize,
    () => deps.deleteWithEtag(existing.etag),
  );

  if (status === 412) {
    const latest = await deps.readEvent();
    status = latest.status === 200
      ? await withProviderMutationFence(
        deps.authorize,
        () => deps.deleteWithEtag(latest.etag),
      )
      : latest.status;
  }

  return status;
}
