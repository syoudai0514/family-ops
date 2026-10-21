import { assertEquals } from 'jsr:@std/assert@1';
import { acknowledgeLineImage } from './lineReceipt.ts';
Deno.test('image receipt marks read and starts loading in parallel without spending a reply token', async () => {
  const saved = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN');
  Deno.env.set('LINE_CHANNEL_ACCESS_TOKEN', 'test');
  const calls: Array<{ url: string; body: unknown }> = [];
  const releases: Array<() => void> = [];
  try {
    const result = acknowledgeLineImage('read-token', 'user', (url, init) => {
      calls.push({ url: String(url), body: JSON.parse(String((init as RequestInit | undefined)?.body)) });
      return new Promise<Response>((resolve) =>
        releases.push(() => resolve(Response.json({})))
      );
    });
    assertEquals(calls, [{
      url: 'https://api.line.me/v2/bot/chat/markAsRead',
      body: { markAsReadToken: 'read-token' },
    }, {
      url: 'https://api.line.me/v2/bot/chat/loading/start',
      body: { chatId: 'user', loadingSeconds: 30 },
    }]);
    releases.forEach((release) => release());
    await result;
    await acknowledgeLineImage(undefined, undefined, () => {
      throw new Error('must not fetch');
    });
    await acknowledgeLineImage(
      'expired',
      undefined,
      () => Promise.reject(new Error('offline')),
    );
  } finally {
    if (saved === undefined) Deno.env.delete('LINE_CHANNEL_ACCESS_TOKEN');
    else Deno.env.set('LINE_CHANNEL_ACCESS_TOKEN', saved);
  }
});
