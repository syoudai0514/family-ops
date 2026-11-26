import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import type { RequestNotificationItem } from './requestNotificationPayload.ts';

type Handler = (request: Request) => Promise<Response>;

Deno.test('notification worker delivers request content and exact LINE actions', async (t) => {
  const env = {
    SUPABASE_URL: 'https://requests-test.supabase.co',
    SUPABASE_SERVICE_ROLE_KEY: 'test-service',
    CRON_WORKER_TOKEN: 'test-worker',
    LINE_CHANNEL_ACCESS_TOKEN: 'test-line',
    WEB_PUSH_VAPID_PUBLIC_KEY: '',
    WEB_PUSH_VAPID_PRIVATE_KEY: '',
  };
  const previous = Object.fromEntries(Object.keys(env).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  const originalFetch = globalThis.fetch;
  const originalServe = Object.getOwnPropertyDescriptor(Deno, 'serve')!;
  let handler: Handler | undefined;
  Object.defineProperty(Deno, 'serve', { configurable: true, value: (value: Handler) => { handler = value; } });

  const generalId = '11111111-1111-4111-8111-111111111111';
  const assignmentId = '22222222-2222-4222-8222-222222222222';
  const attemptId = '33333333-3333-4333-8333-333333333333';
  let items: RequestNotificationItem[] = [];
  let requestLookup: URL | undefined;
  const pushes: Array<{ to: string; messages: Array<{ type: string; text?: string; quickReply?: unknown }> }> = [];
  globalThis.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.hostname === 'api.line.me' && url.pathname === '/v2/bot/message/push') {
      pushes.push(JSON.parse(String(init?.body)));
      return Promise.resolve(Response.json({}));
    }
    if (url.hostname !== 'requests-test.supabase.co') return Promise.reject(new Error('unexpected provider'));
    const rpc = url.pathname.split('/rpc/')[1];
    switch (rpc) {
      case 'server_tx_dispatch_schedule_reminders':
      case 'server_tx_dispatch_morning_nudges':
        return Promise.resolve(Response.json(0));
      case 'server_tx_web_push_vapid_keys':
        return Promise.resolve(Response.json(null));
      case 'server_tx_get_line_quota_refresh_state':
        return Promise.resolve(Response.json({ stale: false }));
      case 'server_tx_claim_notification_outbox_batch':
        return Promise.resolve(Response.json([{
          id: 'outbox',
          household_id: 'household',
          recipient_user_id: 'recipient',
          type: items[0]?.type,
          payload: { items },
          dedup_key: 'request',
          priority: 'normal',
          attempts: 1,
          provider_retry_key: generalId,
          lease_token: 'lease',
          line_user_id: 'line-recipient',
        }]));
      case 'server_tx_reserve_line_quota':
        return Promise.resolve(Response.json({ permitted: true }));
      case 'server_tx_complete_notification_outbox_item':
        return Promise.resolve(Response.json({ ok: true, status: 'sent' }));
    }
    if (url.pathname.endsWith('/requests')) {
      requestLookup = url;
      return Promise.resolve(Response.json([{
        request_kind: 'light', shared_title: '古いお願い', shared_message: 'この品を買ってください。',
      }]));
    }
    return Promise.reject(new Error('unexpected request'));
  };

  const send = async (...entries: RequestNotificationItem[]) => {
    items = entries;
    pushes.length = 0;
    requestLookup = undefined;
    const response = await handler!(new Request('https://edge.test/send-notifications', {
      method: 'POST',
      headers: { 'X-Family-Ops-Worker-Token': env.CRON_WORKER_TOKEN },
      body: '{}',
    }));
    assertEquals(response.status, 200);
    assertEquals((await response.json()).sent, 1);
    assertEquals(pushes.map((push) => push.to), ['line-recipient']);
    return pushes[0].messages;
  };

  try {
    await import('./index.ts');
    Object.defineProperty(Deno, 'serve', originalServe);

    await t.step('general request preserves its confirmed title and message even if it mentions pickup', async () => {
      const messages = await send({
        type: 'request_received',
        title: 'お願いが届きました',
        body: 'お迎え前に薬を受け取る',
        payload: {
          request_id: generalId,
          attempt_id: attemptId,
          revision: 1,
          terms_revision: 1,
          request_kind: 'general',
          shared_title: 'お迎え前に薬を受け取る',
          shared_message: '受付で名前を伝えてね。',
          due_at: '2026-11-25T09:30:00Z',
          reply_due_at: '2026-11-25T05:00:00Z',
        },
      });
      assertEquals(requestLookup, undefined);
      assertStringIncludes(messages[0].text!, 'お迎え前に薬を受け取る\n受付で名前を伝えてね。');
      assertStringIncludes(messages[0].text!, '作業期限：11/25 18:30\n返事期限：11/25 14:00');
      assertStringIncludes(messages[0].text!, '引き受けるまでタスクにはなりません。');
      const card = JSON.stringify(messages[1]);
      const action = `action=mc_request&request_id=${generalId}&attempt_id=${attemptId}`;
      assertStringIncludes(card, `${action}&request_action=accept&revision=1&terms_revision=1`);
      assertStringIncludes(card, `${action}&request_action=decline&revision=1&terms_revision=1`);
      assertStringIncludes(card, `action=mc_request_open&request_id=${generalId}`);
      assertEquals(card.includes('担当変更'), false);
    });

    await t.step('transport handoff shows the occurrence and keeps its Flex alongside bundled text', async () => {
      const messages = await send({
        type: 'request.received',
        title: '担当変更のお願い',
        body: '通院のため、代われますか？',
        payload: {
          request_id: assignmentId,
          attempt_id: attemptId,
          revision: 1,
          terms_revision: 1,
          request_kind: 'assignment_change',
          shared_title: 'お迎え',
          shared_message: '通院のため、代われますか？',
          due_at: '2026-11-25T09:30:00Z',
          scope: 'once',
        },
      }, { type: 'handover', title: '朝のチェック', body: '明日は体操着' });
      assertEquals(messages.map((message) => message.type), ['text', 'flex']);
      assertStringIncludes(messages[0].text!, '朝のチェック\n明日は体操着');
      assertStringIncludes(messages[0].text!, 'お迎え\n通院のため、代われますか？\n対象日時：11/25 18:30');
      assertStringIncludes(messages[0].text!, '引き受けが確定するまで担当は変わりません。');
      assertStringIncludes(JSON.stringify(messages[1]),
        `action=prompt_accept_assignment_change&request_id=${assignmentId}&attempt_id=${attemptId}&revision=1&terms_revision=1`);
    });

    await t.step('legacy request without the response snapshot can open the current request', async () => {
      const messages = await send({
        type: 'request.received', title: 'お願いが届きました', body: '古いお願い',
        payload: { request_id: generalId },
      });
      assertEquals(requestLookup?.searchParams.get('household_id'), 'eq.household');
      assertEquals(requestLookup?.searchParams.get('recipient_id'), 'eq.recipient');
      assertEquals(messages.map((message) => message.type), ['text', 'flex']);
      assertStringIncludes(messages[0].text!, '古いお願い\nこの品を買ってください。');
      assertStringIncludes(JSON.stringify(messages[1]), `action=mc_request_open&request_id=${generalId}`);
    });

    await t.step('consultation and first confirmation are actionable and stay visibly unconfirmed', async () => {
      const consultation = {
        request_id: assignmentId,
        request_kind: 'assignment_change',
        shared_title: 'お迎え',
        shared_message: '元の依頼文',
      };
      const started = await send({ type: 'request.consulting', payload: { ...consultation, consultation_event: 'started' } });
      assertStringIncludes(started[0].text!, '相手が相談を始めました。');
      const updated = await send({
        type: 'request.consulting',
        body: '本文に使わない未確定メモ',
        payload: { ...consultation, consultation_event: 'updated', proposed_due_at: '2026-11-25T09:30:00Z' },
      });
      assertStringIncludes(updated[0].text!, '相手が相談内容を更新しました。\nお迎え\n提案中の作業期限：11/25 18:30');
      assertStringIncludes(updated[0].text!, '二人が同じ条件を確認するまで担当は変わりません。');
      assertEquals(updated[0].text?.includes('本文に使わない未確定メモ'), false);
      assertStringIncludes(JSON.stringify(updated[1]), `action=mc_request_open&request_id=${assignmentId}`);
      const awaiting = await send({ type: 'request.awaiting_confirmation', payload: consultation });
      assertStringIncludes(awaiting[0].text!, '相手が相談中の条件を確認しました。');
      assertStringIncludes(awaiting[0].text!, '担当は変わりません');
      const accepted = await send({ type: 'request.accepted', payload: { ...consultation, confirmation_mode: 'mutual' } });
      assertEquals(accepted[0].text, '二人が同じ条件を確認しました。\nお迎え\n担当変更が確定しました。');
    });

    await t.step('checking copy distinguishes the first tap, reminder, and generic checking', async () => {
      const payload = { request_id: assignmentId, shared_title: 'お迎え' };
      const tapped = await send({
        type: 'request.checking', payload: { ...payload, followup: 'recipient_final_confirmation' },
      });
      assertStringIncludes(tapped[0].text!, '相手が「引き受ける」を押しました。\nお迎え\n最終確認待ちです。');
      const reminder = await send({ type: 'request.checking', payload: { ...payload, reminder: 'final_confirmation' } });
      assertStringIncludes(reminder[0].text!, '最終確認が残っています。');
      assertStringIncludes(JSON.stringify(reminder[1]), `action=mc_request_open&request_id=${assignmentId}`);
      const generic = await send({ type: 'request.checking', payload });
      assertEquals(generic[0].text, '相手が確認中です。\nお迎え\nまだ成立していません。');
    });
  } finally {
    globalThis.fetch = originalFetch;
    Object.defineProperty(Deno, 'serve', originalServe);
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
});
