export interface ProviderMutationAuthorization {
  authorized: boolean;
  reason?: string;
  mutation_fence_id?: string;
  request_deadline_at?: string;
}

export class ProviderMutationFencedError extends Error {
  readonly reason: string;

  constructor(reason = "PROVIDER_MUTATION_NOT_AUTHORIZED") {
    super(reason);
    this.name = "ProviderMutationFencedError";
    this.reason = reason;
  }
}

export class ProviderMutationDeadlineError extends Error {
  constructor() {
    super("PROVIDER_MUTATION_REQUEST_DEADLINE_EXCEEDED");
    this.name = "ProviderMutationDeadlineError";
  }
}

/**
 * Runs one provider mutation only after a fresh durable ownership check.
 *
 * Authorization now also establishes a durable DB-side provider-mutation
 * fence with a short request deadline.  We intentionally bound how long the
 * worker awaits the provider Promise.  The underlying HTTP implementation may
 * still complete remotely after this local deadline; that is why the DB fence
 * remains unresolved/uncertain and ownership transfer requires a quarantine +
 * provider revalidation rather than assuming a client timeout cancelled the
 * remote mutation.
 *
 * Call this separately for every DELETE/INSERT/PATCH attempt; a retry is a new
 * provider mutation and therefore requires a new authorization/fence.
 */
export async function withProviderMutationFence<T>(
  authorize: () => Promise<ProviderMutationAuthorization>,
  mutate: () => Promise<T>,
): Promise<T> {
  const authorization = await authorize();
  if (!authorization.authorized) {
    throw new ProviderMutationFencedError(
      authorization.reason ?? "PROVIDER_MUTATION_NOT_AUTHORIZED",
    );
  }

  const deadline = authorization.request_deadline_at
    ? Date.parse(authorization.request_deadline_at)
    : Number.NaN;
  if (!Number.isFinite(deadline)) {
    // An authorized provider mutation without a durable deadline would reopen
    // the exact in-flight stale-request gap this fence exists to close.
    throw new ProviderMutationFencedError("PROVIDER_MUTATION_DEADLINE_MISSING");
  }

  const remainingMs = deadline - Date.now();
  if (remainingMs <= 0) throw new ProviderMutationDeadlineError();

  let timer: number | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new ProviderMutationDeadlineError()), remainingMs);
  });

  try {
    return await Promise.race([mutate(), timeout]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
