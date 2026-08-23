const WORKERS = ['process-line-inbox', 'process-pending-actions', 'send-notifications'] as const;

export type WorkerKickResult = { ok: boolean; failedWorker: string | null };

/**
 * Best-effort only. The signed webhook is already durable before this runs;
 * a failed kick intentionally leaves the item for the existing minute cron.
 */
export async function kickLineWorkers(
  baseUrl: string,
  workerToken: string,
  fetcher: typeof fetch = fetch,
): Promise<WorkerKickResult> {
  if (!baseUrl || !workerToken) return { ok: false, failedWorker: 'configuration' };
  for (const worker of WORKERS) {
    try {
      const response = await fetcher(`${baseUrl.replace(/\/$/, '')}/functions/v1/${worker}`, {
        method: 'POST',
        headers: { 'X-Family-Ops-Worker-Token': workerToken },
        signal: AbortSignal.timeout(25_000),
      });
      if (!response.ok) return { ok: false, failedWorker: worker };
    } catch {
      return { ok: false, failedWorker: worker };
    }
  }
  return { ok: true, failedWorker: null };
}
