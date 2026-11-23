import { assertEquals } from 'jsr:@std/assert@1';

type Handler = (req: Request) => Promise<Response>;
Deno.test('assignment review authenticates the caller and never accepts an actor from the body', async () => {
  const env = { SUPABASE_URL: 'https://review-test.supabase.co', SUPABASE_ANON_KEY: 'test-anon', SUPABASE_SERVICE_ROLE_KEY: 'test-service' };
  const oldEnv = Object.fromEntries(Object.keys(env).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  const originalFetch = globalThis.fetch;
  const originalServe = Object.getOwnPropertyDescriptor(Deno, 'serve')!;
  let handler: Handler | undefined;
  Object.defineProperty(Deno, 'serve', { configurable: true, value: (value: Handler) => { handler = value; } });
  const actor = '11111111-1111-4111-8111-111111111111';
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  globalThis.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.hostname !== 'review-test.supabase.co') return Promise.reject(new Error('unexpected provider'));
    if (url.pathname === '/auth/v1/user') return Promise.resolve(Response.json({ id: actor, aud: 'authenticated' }));
    const name = url.pathname.split('/rpc/')[1];
    if (!name) return Promise.reject(new Error('unexpected request'));
    calls.push({ name, args: JSON.parse(String(init?.body ?? '{}')) });
    return Promise.resolve(Response.json(name === 'server_read_assignment_review_v1' ? { routines: [], transport_tentative: false } : { ok: true }));
  };
  const post = (body: Record<string, unknown>, auth = true) => handler!(new Request('https://edge.example/review', {
    method: 'POST', headers: { 'content-type': 'application/json', ...(auth ? { authorization: 'Bearer test-token' } : {}) }, body: JSON.stringify(body),
  }));
  try {
    await import('./index.ts');
    Object.defineProperty(Deno, 'serve', originalServe);
    assertEquals((await post({ action: 'read' }, false)).status, 401);
    assertEquals(calls.length, 0);
    assertEquals((await post({ action: 'read', actor_id: 'imposter' })).status, 200);
    assertEquals(calls[0], { name: 'server_read_assignment_review_v1', args: { p_actor_id: actor } });
    assertEquals((await post({ action: 'stop', task_definition_id: 'task' })).status, 400);
    assertEquals(calls.length, 1);
    assertEquals((await post({ action: 'stop', task_definition_id: 'task', operation_id: 'op', actor_id: 'imposter' })).status, 200);
    assertEquals(calls[1], { name: 'server_tx_review_assignment_v1', args: { p_actor_id: actor, p_definition_id: 'task', p_operation_id: 'op', p_action: 'stop' } });
    assertEquals((await post({ action: 'unknown', task_definition_id: 'task', operation_id: 'op' })).status, 400);
    assertEquals(calls.length, 2);
  } finally {
    globalThis.fetch = originalFetch;
    Object.defineProperty(Deno, 'serve', originalServe);
    for (const [key, value] of Object.entries(oldEnv)) { if (value === undefined) Deno.env.delete(key); else Deno.env.set(key, value); }
  }
});
