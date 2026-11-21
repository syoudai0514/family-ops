import { assertEquals } from 'jsr:@std/assert@1';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { loadPreviousDayReminder } from './previousDayReminder.ts';
import { buildBriefQuickReply } from './briefQuickReply.ts';

function fixture(recordings: unknown[], tasks: unknown[]) {
  const calls: Array<{ table: string; method: string; args: unknown[] }> = [];
  const client = {
    from(table: string) {
      const query: Record<string, unknown> = {};
      for (const method of ['select', 'eq', 'is', 'gte', 'in']) {
        query[method] = (...args: unknown[]) => { calls.push({ table, method, args }); return query; };
      }
      query.limit = () => Promise.resolve({ data: table === 'task_events' ? recordings : tasks, error: null });
      return query;
    },
  } as unknown as SupabaseClient;
  return { client, calls };
}

Deno.test('previous-day follow-up is limited to people who recently recorded work', async () => {
  const inactive = fixture([], [{ id: 'task' }]);
  assertEquals(await loadPreviousDayReminder(inactive.client, 'household', 'mama', new Date('2026-11-21T00:00:00Z')), null);
  assertEquals(inactive.calls.some((call) => call.table === 'task_instances'), false);

  const active = fixture([{ id: 'recording' }], [{ id: 'task' }]);
  assertEquals(await loadPreviousDayReminder(active.client, 'household', 'papa', new Date('2026-11-21T00:00:00Z')), {
    date: '2026-11-20', text: '昨日の分、まとめて済みにしますか？',
  });
  assertEquals(active.calls.some((call) => call.table === 'task_events' && call.method === 'eq' && call.args[0] === 'actor_id' && call.args[1] === 'papa'), true);

  const nothingOpen = fixture([{ id: 'recording' }], []);
  assertEquals(await loadPreviousDayReminder(nothingOpen.client, 'household', 'papa', new Date('2026-11-21T00:00:00Z')), null);
});

Deno.test('follow-up buttons keep the original date and provide a no-op', () => {
  const buttons = buildBriefQuickReply('daily_brief.v2', { previousDay: '2026-12-31' })!;
  assertEquals(buttons.slice(0, 2), [
    { type: 'postback', label: 'ぜんぶ済み', data: 'action=previous_day_complete&date=2026-12-31', displayText: 'ぜんぶ済み' },
    { type: 'postback', label: 'そのまま', data: 'action=previous_day_keep', displayText: 'そのまま' },
  ]);
});
