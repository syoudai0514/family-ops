// LINE OpenAPI: markAsReadToken belongs to the received message, not its user ID.
// Called only after the signature is checked and that message is durably stored.
export async function acknowledgeLineImage(
  markAsReadToken: string | undefined,
  userId: string | undefined,
  fetcher: typeof fetch = fetch,
): Promise<void> {
  const token = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN');
  if (!token) return;
  const requests: Array<[string, Record<string, unknown>]> = [];
  if (markAsReadToken) requests.push(['chat/markAsRead', { markAsReadToken }]);
  if (userId) {
    requests.push(['chat/loading/start', {
      chatId: userId,
      loadingSeconds: 30,
    }]);
  }
  await Promise.all(requests.map(async ([path, body]) => {
    try {
      const response = await fetcher(`https://api.line.me/v2/bot/${path}`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(3_000),
      });
      if (!response.ok) {
        console.warn('LINE image receipt unavailable', {
          endpoint: path,
          status: response.status,
        });
      }
    } catch {
      console.warn('LINE image receipt unavailable', { endpoint: path });
    }
  }));
}
