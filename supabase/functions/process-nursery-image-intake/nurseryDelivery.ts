/** Drain an already durable fallback immediately instead of waiting for minute cron. */
export async function kickNotificationDelivery(
  fetcher: typeof fetch = fetch,
): Promise<void> {
  const base = Deno.env.get('SUPABASE_URL')?.replace(/\/$/, '');
  const token = Deno.env.get('CRON_WORKER_TOKEN');
  if (!base || !token) return;
  try {
    const response = await fetcher(`${base}/functions/v1/send-notifications`, {
      method: 'POST',
      headers: { 'X-Family-Ops-Worker-Token': token },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) {
      console.warn('nursery delivery deferred to cron', {
        status: response.status,
      });
    }
  } catch {
    console.warn('nursery delivery kick unavailable; durable outbox retained');
  }
}
