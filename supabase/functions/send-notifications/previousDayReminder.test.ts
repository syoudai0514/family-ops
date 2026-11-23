import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { loadPreviousDayReminder } from './previousDayReminder.ts';
import { buildBriefQuickReply } from './briefQuickReply.ts';

const noteId = '11111111-1111-4111-8111-111111111111';
const batchId = '22222222-2222-4222-8222-222222222222';
const now = new Date('2026-11-21T00:00:00Z');
const payload = { items: [{ type: 'daily_brief.v2', title: '朝のおうちノート', user_notification_id: noteId }] };

Deno.test('previous-day follow-up is bound to the sender and server snapshot', async () => {
  const calls: unknown[] = [];
  let data: unknown = null;
  const client = { rpc(name: string, args: unknown) { calls.push({ name, args }); return Promise.resolve({ data, error: null }); } } as unknown as SupabaseClient;
  assertEquals(await loadPreviousDayReminder(client, 'papa', payload, now), null);
  data = { id: batchId, date: '2026-11-20', status: 'ready' };
  assertEquals(await loadPreviousDayReminder(client, 'papa', payload, now), {
    id: batchId, date: '2026-11-20', text: '昨日の自分の分、記録しますか？（任意・コドモン送信を除く）',
  });
  assertEquals(calls[1], { name: 'server_tx_prepare_previous_day_consent_v1', args: { p_actor_id: 'papa', p_notification_id: noteId } });
  data = { id: batchId, date: '2026-11-19', status: 'ready' };
  assertEquals(await loadPreviousDayReminder(client, 'papa', payload, now), null);
  assertEquals(await loadPreviousDayReminder(client, 'papa', { items: [{ title: 'other' }, ...payload.items] }, now), null);
});

Deno.test('follow-up buttons bind the server snapshot and offer a no-op', () => {
  const buttons = buildBriefQuickReply('daily_brief.v2', { previousDay: { date: '2026-12-31', id: batchId } })!;
  assertEquals(buttons[0].type, 'postback');
  assertStringIncludes(buttons[0].type === 'postback' ? buttons[0].data : '', `batch_id=${batchId}`);
  assertEquals(buttons[1], { type: 'postback', label: 'そのまま', data: 'action=previous_day_keep', displayText: 'そのまま' });
});
