import { assert, assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';

type Handler = (req: Request) => Promise<Response>;
Deno.test('nursery HTTP: real model payload survives canonical validation and replies immediately', async (t) => {
  const env = {
    SUPABASE_URL: 'https://nursery-test.supabase.co',
    SUPABASE_SERVICE_ROLE_KEY: 'service-test',
    CRON_WORKER_TOKEN: 'worker-test',
    LINE_CHANNEL_ACCESS_TOKEN: 'line-test',
    GEMINI_API_KEY: 'gemini-test',
    GEMINI_MODEL_VISION: 'gemini-3.8-flash',
    APP_BASE_URL: 'https://family.example',
    TEST_MODE: '0',
  };
  const saved = Object.fromEntries(
    Object.keys(env).map((k) => [k, Deno.env.get(k)]),
  );
  for (const [k, v] of Object.entries(env)) Deno.env.set(k, v);
  const originalFetch = globalThis.fetch;
  const originalServe = Object.getOwnPropertyDescriptor(Deno, 'serve')!;
  let handler: Handler | undefined;
  Object.defineProperty(Deno, 'serve', {
    configurable: true,
    value: (h: Handler) => {
      handler = h;
    },
  });
  const id = '11111111-1111-4111-8111-111111111111';
  const context = '22222222-2222-4222-8222-222222222222';
  const calls: Array<{ path: string; body: Record<string, unknown> }> = [];
  let replyFails = false;
  let geminiFails = false;
  let recorded: Record<string, unknown> | undefined;
  const modelResult = {
    triage: 'nursery_notice',
    same_document_as_previous: false,
    child_school_context_id: context,
    context_confidence: 'high',
    ambiguous_fields: [],
    source_facts: [],
    ai_candidates: [],
    review_items: [
      {
        candidate_key: 'model metadata must disappear',
        source_locator: 'names must disappear',
        origin: 'source_explicit',
        item_kind: 'task',
        classification: 'recommended',
        source_page: 1,
        confidence_band: 'high',
        proposed_value: {
          title: 'エプロン・三角巾・マスクを準備',
          due_date: '2026-10-26',
        },
      },
      {
        candidate_key: 'other',
        origin: 'source_explicit',
        item_kind: 'shared_info',
        classification: 'other',
        source_page: 1,
        confidence_band: 'high',
        proposed_value: { text: '汚れてもよい服で登園', date: '2026-10-22' },
      },
    ],
  };
  globalThis.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const body = typeof init?.body === 'string' ? JSON.parse(init.body) : {};
    calls.push({ path: url.pathname, body });
    if (url.hostname === 'generativelanguage.googleapis.com') {
      assert(init?.signal, 'Gemini must have a timeout');
      assertStringIncludes(url.pathname, 'gemini-3.8-flash:generateContent');
      assertEquals(body.generationConfig.thinkingConfig, {
        thinkingLevel: 'low',
      });
      assertEquals(body.generationConfig.maxOutputTokens, 4096);
      assertEquals(
        new Headers(init?.headers).get('x-goog-api-key'),
        'gemini-test',
      );
      assertEquals(url.search, '');
      assertStringIncludes(body.contents[0].parts[0].text, '2026-10-20');
      if (geminiFails) {
        return Promise.resolve(new Response('{}', { status: 503 }));
      }
      const text = JSON.stringify(modelResult);
      return Promise.resolve(
        Response.json({
          candidates: [{
            content: {
              parts: [{ thought: true, text: 'private reasoning' }, {
                text: text.slice(0, 30),
              }, { text: text.slice(30) }],
            },
          }],
        }),
      );
    }
    if (url.hostname === 'api-data.line.me') {
      return Promise.resolve(
        new Response(new Uint8Array([1, 2, 3]), {
          headers: { 'Content-Type': 'image/jpeg' },
        }),
      );
    }
    if (url.hostname === 'api.line.me') {
      return Promise.resolve(
        Response.json({}, { status: replyFails ? 400 : 200 }),
      );
    }
    const rpc = url.pathname.split('/rpc/')[1];
    if (rpc) {
      let data: unknown;
      switch (rpc) {
        case 'server_tx_claim_nursery_line_images':
          assertEquals(body.p_limit, 3);
          data = [{
            id,
            provider_event_id: 'event',
            line_message_id: 'image',
            household_id: 'household',
            actor_id: 'actor',
            line_user_id: 'line-user',
            revision: 2,
            received_at: '2026-10-20T12:18:00Z',
          }];
          break;
        case 'server_read_previous_nursery_image':
          data = { found: false };
          break;
        case 'server_read_validate_nursery_review_items': {
          const items = body.p_items as Array<Record<string, unknown>>;
          assertEquals(items.map((i) => i.classification), [null, null]);
          assertEquals(items[0].candidate_key, 'item-1-task');
          assertEquals(items[0].source_locator, 'p1:item1');
          data = { items, dropped: 0 };
          break;
        }
        case 'server_read_nursery_source_locator':
          data = {
            available: true,
            storage_object_key: 'nursery-r0/canonical-source',
          };
          break;
        case 'server_tx_prepare_nursery_line_source':
          data = { revision: 3 };
          break;
        case 'server_tx_record_nursery_line_analysis':
          recorded = body;
          data = { revision: 4 };
          break;
        case 'server_read_nursery_line_delivery_context':
          data = {
            household_id: 'household',
            received_at: '2026-10-20T12:18:00Z',
            reply_token: 'reply',
            object_key: 'household/photo.jpg',
          };
          break;
        case 'server_tx_finish_nursery_image_review':
          data = { revision: 4 };
          break;
        case 'server_tx_enqueue_immediate_line_push':
          data = { queued: true };
          break;
        default:
          throw new Error(`Unexpected RPC ${rpc}`);
      }
      return Promise.resolve(Response.json(data));
    }
    if (url.pathname === '/rest/v1/child_school_contexts') {
      return Promise.resolve(
        Response.json([{
          id: context,
          school_display_name: '園',
          class_display_name: 'すだちぐみ',
          recognition_aliases: [],
        }]),
      );
    }
    if (
      url.pathname.includes('/storage/v1/object/') && init?.method === 'POST'
    ) return Promise.resolve(Response.json({ Key: 'photo' }));
    if (url.pathname.includes('/storage/v1/object/')) {
      return Promise.resolve(
        new Response(new Uint8Array([1, 2, 3]), {
          headers: { 'Content-Type': 'image/jpeg' },
        }),
      );
    }
    if (url.pathname === '/functions/v1/send-notifications') {
      return Promise.resolve(Response.json({ sent: 1 }));
    }
    throw new Error(`Unexpected request ${url.pathname}`);
  };
  try {
    await import('./index.ts');
    assert(handler);
    const request = (body = {}) =>
      new Request('https://worker.example', {
        method: 'POST',
        headers: { 'X-Family-Ops-Worker-Token': 'worker-test' },
        body: JSON.stringify(body),
      });
    await t.step(
      'unauthorized callers never reach DB or providers',
      async () => {
        assertEquals(
          (await handler!(
            new Request('https://worker.example', { method: 'POST' }),
          )).status,
          401,
        );
        assertEquals(calls.length, 0);
      },
    );
    await t.step(
      'successful notice records actionable items then replies without push/cron',
      async () => {
        assertEquals(await (await handler!(request())).json(), {
          claimed: 1,
          processed: 1,
        });
        assertEquals(recorded?.p_status, 'review_ready');
        assertEquals((recorded?.p_review_items as unknown[]).length, 2);
        const prepare = calls.findIndex((c) =>
          c.path.endsWith('server_tx_prepare_nursery_line_source')
        );
        const upload = calls.findIndex((c) =>
          c.path ===
            '/storage/v1/object/nursery-source/nursery-r0/canonical-source'
        );
        const record = calls.findIndex((c) =>
          c.path.endsWith('server_tx_record_nursery_line_analysis')
        );
        assert(prepare >= 0 && upload > prepare && record > upload);
        assert(calls.find((c) => c.path === '/v2/bot/message/reply'));
        assert(
          !calls.some((c) =>
            c.path.includes('enqueue_immediate') ||
            c.path.includes('send-notifications')
          ),
        );
      },
    );
    await t.step(
      'expired reply tokens enqueue once and kick delivery immediately',
      async () => {
        calls.length = 0;
        replyFails = true;
        assertEquals((await handler!(request())).status, 200);
        const enqueue = calls.findIndex((c) =>
          c.path.endsWith('server_tx_enqueue_immediate_line_push')
        );
        const kick = calls.findIndex((c) =>
          c.path.endsWith('send-notifications')
        );
        assert(enqueue >= 0 && kick > enqueue);
      },
    );
    await t.step(
      'provider outages report processing errors without asking for a new photo',
      async () => {
        calls.length = 0;
        geminiFails = true;
        replyFails = false;
        assertEquals(await (await handler!(request())).json(), {
          claimed: 1,
          processed: 0,
        });
        assert(
          !calls.some((c) => c.path.includes('prepare_nursery_line_source')),
        );
        const reply = calls.find((c) => c.path === '/v2/bot/message/reply')!
          .body as { messages: Array<{ text: string }> };
        assertStringIncludes(reply.messages[0].text, '処理中にエラー');
        assert(!reply.messages[0].text.includes('撮り直し'));
      },
    );
    await t.step(
      'stored-photo release check has no business writes or LINE sends',
      async () => {
        calls.length = 0;
        geminiFails = false;
        const response = await handler!(request({ validation_intake_id: id }));
        const result = await response.json();
        assertEquals(result.validated, true);
        assertEquals(result.model, 'gemini-3.8-flash');
        assertEquals(result.item_count, 2);
        assert(!JSON.stringify(result).includes('エプロン'));
        assert(
          !calls.some((c) =>
            c.path.includes('server_tx_') || c.path.includes('/v2/bot/')
          ),
        );
      },
    );
  } finally {
    globalThis.fetch = originalFetch;
    Object.defineProperty(Deno, 'serve', originalServe);
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) Deno.env.delete(k);
      else Deno.env.set(k, v);
    }
  }
});
