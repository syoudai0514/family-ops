import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';

type Handler = (req: Request) => Promise<Response>;

Deno.test('notification worker sends bulk button only with its visible scope', async (t) => {
  const env = { SUPABASE_URL: 'https://bulk-test.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'test-service',
    CRON_WORKER_TOKEN: 'test-worker', LINE_CHANNEL_ACCESS_TOKEN: 'test-line-token', APP_BASE_URL: 'https://app.example.com',
    WEB_PUSH_VAPID_PUBLIC_KEY: '', WEB_PUSH_VAPID_PRIVATE_KEY: '' };
  const previous = Object.fromEntries(Object.keys(env).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  const originalFetch = globalThis.fetch;
  const originalServe = Object.getOwnPropertyDescriptor(Deno, 'serve')!;
  let handler: Handler | undefined;
  Object.defineProperty(Deno, 'serve', { configurable: true, value: (value: Handler) => { handler = value; } });
  const notificationId = '11111111-1111-4111-8111-111111111111';
  const batchId = '22222222-2222-4222-8222-222222222222';
  const pushes: Array<Record<string, unknown>> = [];
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  let unavailable = false;
  let phase: 'morning' | 'evening' = 'morning';
  let body = '今日の内容';
  globalThis.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const args = init?.body ? JSON.parse(String(init.body)) : {};
    if (url.hostname === 'api.line.me' && url.pathname === '/v2/bot/message/push') {
      pushes.push(args); return Promise.resolve(Response.json({}));
    }
    if (url.hostname !== 'bulk-test.supabase.co') return Promise.reject(new Error('unexpected provider'));
    const name = url.pathname.split('/rpc/')[1];
    if (name) {
      calls.push({ name, args });
      switch (name) {
        case 'server_tx_dispatch_schedule_reminders': case 'server_tx_dispatch_morning_nudges': return Promise.resolve(Response.json(0));
        case 'server_tx_web_push_vapid_keys': return Promise.resolve(Response.json(null));
        case 'server_tx_get_line_quota_refresh_state': return Promise.resolve(Response.json({ stale: false }));
        case 'server_tx_claim_notification_outbox_batch': return Promise.resolve(Response.json([{
          id: 'outbox', household_id: 'household', recipient_user_id: 'actor', type: 'daily_brief.v2',
          payload: { items: [{ type: 'daily_brief.v2', title: phase === 'morning' ? '朝のおうちノート' : '夜のおうちノート',
            body, user_notification_id: notificationId }] },
          dedup_key: 'daily', priority: 'normal', attempts: 1, provider_retry_key: batchId,
          business_expires_at: null, quota_reservation_id: null, lease_token: 'lease', line_user_id: 'line-user',
        }]));
        case 'server_tx_reserve_line_quota': return Promise.resolve(Response.json({ permitted: true }));
        case 'server_read_thanks_candidates': return Promise.resolve(Response.json([]));
        case 'server_tx_prepare_line_bulk_v1': return unavailable
          ? Promise.resolve(Response.json({ message: 'unavailable' }, { status: 503 }))
          : Promise.resolve(Response.json({ id: batchId, phase, status: 'ready' }));
        case 'server_tx_complete_notification_outbox_item': return Promise.resolve(Response.json({ ok: true, status: 'sent' }));
        default: return Promise.reject(new Error(`unexpected RPC ${name}`));
      }
    }
    if (url.pathname.endsWith('/task_events')) return Promise.resolve(Response.json([]));
    return Promise.reject(new Error('unexpected request'));
  };
  const run = async () => {
    pushes.length = 0; calls.length = 0;
    const response = await handler!(new Request('https://edge.example/send-notifications', {
      method: 'POST', headers: { 'X-Family-Ops-Worker-Token': env.CRON_WORKER_TOKEN }, body: '{}',
    }));
    assertEquals(response.status, 200);
    assertEquals((await response.json()).sent, 1);
    assertEquals(pushes.length, 1);
    return JSON.stringify(pushes[0]);
  };
  try {
    await import('./index.ts');
    Object.defineProperty(Deno, 'serve', originalServe);
    await t.step('morning button names its scope and excludes Codmon submission', async () => {
      const sent = await run();
      assertStringIncludes(sent, '朝の分ぜんぶOK');
      assertStringIncludes(sent, 'コドモン送信を除く');
      assertStringIncludes(sent, `batch_id=${batchId}`);
      assertEquals(calls.find((call) => call.name === 'server_tx_prepare_line_bulk_v1')?.args,
        { p_actor_id: 'actor', p_notification_id: notificationId });
    });
    await t.step('evening uses the evening button and the same explicit scope', async () => {
      phase = 'evening';
      const sent = await run();
      assertStringIncludes(sent, '夜の分ぜんぶOK');
      assertStringIncludes(sent, 'コドモン送信を除く');
    });
    await t.step('a truncated note does not offer an action for unseen tasks', async () => {
      body = '長い予定'.repeat(10_000);
      const sent = await run();
      assertEquals(sent.includes('ぜんぶOK'), false);
      assertEquals(sent.includes('コドモン送信を除く'), false);
      assertEquals((pushes[0].messages as unknown[]).length <= 5, true);
      body = '今日の内容';
    });
    await t.step('an unavailable snapshot still sends the ordinary note', async () => {
      unavailable = true;
      const sent = await run();
      assertStringIncludes(sent, '今日の内容');
      assertEquals(sent.includes('ぜんぶOK'), false);
    });
  } finally {
    Object.defineProperty(Deno, 'serve', originalServe);
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) Deno.env.delete(key); else Deno.env.set(key, value);
    }
  }
});
