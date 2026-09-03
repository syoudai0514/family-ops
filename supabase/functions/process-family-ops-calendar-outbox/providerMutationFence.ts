export interface ProviderMutationAuthorization {
  authorized: boolean;
  reason?: string;
}

export class ProviderMutationFencedError extends Error {
  readonly reason: string;

  constructor(reason = "PROVIDER_MUTATION_NOT_AUTHORIZED") {
    super(reason);
    this.name = "ProviderMutationFencedError";
    this.reason = reason;
  }
}

/**
 * Runs one provider mutation only after a fresh durable ownership check.
 * Call this separately for every DELETE/INSERT/PATCH attempt; a retry is a new
 * provider mutation and therefore requires a new authorization.
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
  return await mutate();
}
