import { assertEquals } from 'jsr:@std/assert@1';

type Handler = (req: Request) => Promise<Response>;

Deno.test('complete-task HTTP returns snapshot capability and uses revision-bound undo', async () => {
  const env = { SUPABASE_URL: 'https://checklist-test.supabase.co', SUPABASE_ANON_KEY: 'test-anon', SUPABASE_SERVICE_ROLE_KEY: 'test-service' };
  const previous = Object.fromEntries(Object.keys(env).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  const originalFetch = globalThis.fetch;
  const originalServe = Object.getOwnPropertyDescriptor(Deno, 'serve')!;
  let handler: Handler | undefined;
  Object.defineProperty(Deno, 'serve', { configurable: true, value: (value: Handler) => { handler = value; } });
  const actor = '11111111-1111-4111-8111-111111111111';
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  let conflict = false;
  globalThis.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.hostname !== 'checklist-test.supabase.co') return Promise.reject(new Error('unexpected provider'));
    if (url.pathname === '/auth/v1/user') return Promise.resolve(Response.json({ id: actor, aud: 'authenticated' }));
    if (url.pathname.endsWith('/task_instances')) return Promise.resolve(Response.json([]));
    const name = url.pathname.split('/rpc/')[1];
    if (name) {
      calls.push({ name, args: JSON.parse(String(init?.body ?? '{}')) });
      if (conflict) return Promise.resolve(Response.json({ message: 'AGGREGATE_REVISION_CONFLICT', code: 'P0001' }, { status: 400 }));
      return Promise.resolve(Response.json(name === 'server_tx_complete_task_with_checklist_undo_v1'
        ? { ok: true, revision: 4, checklist_undo_available: true }
        : { ok: true, task_id: 'task', status: 'in_progress', revision: 6 }));
    }
    return Promise.reject(new Error('unexpected request'));
  };
  const post = (body: Record<string, unknown>, auth = true) => handler!(new Request('https://edge.example/complete-task', {
    method: 'POST', headers: { 'content-type': 'application/json', ...(auth ? { authorization: 'Bearer test-token' } : {}) },
    body: JSON.stringify(body),
  }));
  try {
    await import('./index.ts');
    Object.defineProperty(Deno, 'serve', originalServe);
    const denied = await post({ operation_id: 'op', task_id: 'task' }, false);
    assertEquals(denied.status, 401);
    assertEquals(calls.length, 0);
    const completed = await post({ operation_id: 'op', task_id: 'task', completion_actor: 'self', complete_remaining_subtasks: true });
    assertEquals(completed.status, 200);
    assertEquals(await completed.json(), { ok: true, revision: 4, checklist_undo_available: true });
    assertEquals(calls[0], { name: 'server_tx_complete_task_with_checklist_undo_v1', args: {
      p_actor_id: actor, p_operation_id: 'op', p_task_id: 'task', p_completion_actor: 'self',
      p_complete_remaining_subtasks: true, p_source: 'pwa',
    } });
    const reopened = await post({ operation_id: 'undo', task_id: 'task', action: 'reopen', expected_revision: 4 });
    assertEquals(reopened.status, 200);
    assertEquals(calls[1], { name: 'server_tx_reopen_task_with_checklist_undo_v1', args: {
      p_actor_id: actor, p_operation_id: 'undo', p_task_id: 'task', p_expected_revision: 4, p_source: 'pwa',
    } });
    const invalid = await post({ operation_id: 'bad', task_id: 'task', action: 'reopen' });
    assertEquals(invalid.status, 400);
    assertEquals(calls.length, 2);
    conflict = true;
    const stale = await post({ operation_id: 'stale', task_id: 'task', action: 'reopen', expected_revision: 4 });
    assertEquals(stale.status, 409);
    assertEquals((await stale.json()).error.code, 'AGGREGATE_REVISION_CONFLICT');
  } finally {
    globalThis.fetch = originalFetch;
    Object.defineProperty(Deno, 'serve', originalServe);
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) Deno.env.delete(key); else Deno.env.set(key, value);
    }
  }
});
