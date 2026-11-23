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
  let previousBatch: Record<string, unknown> | null = null;
  let weekly: unknown[] = [];
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
        case 'server_tx_log_line_turn': return Promise.resolve(Response.json({ ok: true }));
        case 'server_tx_prepare_previous_day_consent_v1': return Promise.resolve(Response.json(previousBatch));
        case 'server_tx_prepare_weekly_assignment_consent_v1': return Promise.resolve(Response.json(weekly));
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
    await t.step('previous day uses a server-issued snapshot and discloses its scope', async () => {
      const yesterday = new Date(Date.now() + 9 * 3600_000);
      yesterday.setUTCDate(yesterday.getUTCDate() - 1);
      previousBatch = { id: batchId, date: yesterday.toISOString().slice(0, 10), status: 'ready' };
      const sent = await run();
      assertStringIncludes(sent, '昨日の自分の分、記録しますか');
      assertStringIncludes(sent, '任意・コドモン送信を除く');
      assertStringIncludes(sent, `action=previous_day_complete&date=${previousBatch.date}&batch_id=${batchId}`);
      previousBatch = null;
    });
    await t.step('Sunday consent cards keep the original quick replies on the last message', async () => {
      const RealDate = globalThis.Date;
      const sunday = new RealDate('2026-11-29T00:00:00Z').getTime();
      class SundayDate extends RealDate {
        constructor(value?: string | number) { super(value ?? sunday); }
        static override now() { return sunday; }
      }
      weekly = [{ offer_id: batchId, kind: 'rule', snapshot: {
        title: '朝の準備', strategy: 'fixed', phase: 'morning', weekday: 1, scheduled_local_time: '07:10:00',
        effective_from: '2026-11-01', effective_to: null, fallback_assignee_id: null,
        subtasks: [{ title: '体操着', required: true }],
      } }];
      try {
        globalThis.Date = SundayDate as DateConstructor;
        const sent = await run();
        assertStringIncludes(sent, 'この担当でいい？');
        assertStringIncludes(sent, '体操着');
        assertStringIncludes(sent, `offer_id=${batchId}&answer=agree`);
        const messages = pushes[0].messages as Record<string, unknown>[];
        assertEquals(messages.length <= 5, true);
        assertEquals(messages.at(-1)?.type, 'flex');
        assertEquals(Boolean(messages.at(-1)?.quickReply), true);
      } finally {
        globalThis.Date = RealDate;
        weekly = [];
      }
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
