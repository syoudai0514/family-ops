import { assertEquals } from 'jsr:@std/assert@1';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { loadLineBulk } from './lineBulk.ts';

Deno.test('bulk action uses the notification and validated server snapshot', async () => {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const id = '11111111-1111-4111-8111-111111111111';
  const client = { rpc: (name: string, args: Record<string, unknown>) => {
    calls.push({ name, args }); return Promise.resolve({ data: { id, phase: 'morning', status: 'ready' }, error: null });
  } } as unknown as SupabaseClient;
  const payload = { items: [{ type: 'daily_brief.v2', title: '朝のおうちノート', body: '朝の内容', user_notification_id: id }] };
  assertEquals(await loadLineBulk(client, 'actor', payload), { id, phase: 'morning' });
  assertEquals(calls[0], { name: 'server_tx_prepare_line_bulk_v1', args: { p_actor_id: 'actor', p_notification_id: id } });
  assertEquals(await loadLineBulk(client, 'actor', { items: [...payload.items, ...payload.items] }), null);
  assertEquals(await loadLineBulk(client, 'actor', { items: [{ type: 'request.received', title: 'お願い' }, ...payload.items] }), null);
  assertEquals(await loadLineBulk(client, 'actor', { items: [{ ...payload.items[0], body: '長'.repeat(5000) }] }), null);
  assertEquals(await loadLineBulk(client, 'actor', { items: [{ ...payload.items[0], user_notification_id: 'invalid' }] }), null);
  assertEquals(calls.length, 1);
});

Deno.test('an unavailable, malformed, or wrong-phase snapshot leaves the normal brief intact', async () => {
  const id = '11111111-1111-4111-8111-111111111111';
  const payload = { items: [{ type: 'daily_brief.v2', title: '朝のおうちノート', body: '朝の内容', user_notification_id: id }] };
  for (const data of [null, { id, phase: 'evening', status: 'ready' }, { id: 'bad', phase: 'morning', status: 'ready' }]) {
    const client = { rpc: () => Promise.resolve({ data, error: null }) } as unknown as SupabaseClient;
    assertEquals(await loadLineBulk(client, 'actor', payload), null);
  }
  const failed = { rpc: () => Promise.reject(new Error('offline')) } as unknown as SupabaseClient;
  assertEquals(await loadLineBulk(failed, 'actor', payload), null);
});
