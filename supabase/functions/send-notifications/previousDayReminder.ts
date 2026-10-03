import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { formatScheduleDate } from '../process-line-inbox/scheduleLanguage.ts';

export function previousDayReminderText(date: string, titles: string[]): string | null {
  if (!titles.length) return null;
  return [`昨日（${date}）の更新確認`, `${formatScheduleDate(date)}：まだ完了が記録されていません。`,
    ...titles.slice(0, 8).map((title) => `・${title}`),
    ...(titles.length > 8 ? [`ほか ${titles.length - 8} 件`] : []),
    '済んでいたら「昨日のは全部終わっている」「昨日の○○以外は完了」と返信できます。'].join('\n');
}

export async function loadPreviousDayReminder(client: SupabaseClient, householdId: string, recipientId: string, now = new Date()): Promise<{ date: string; text: string } | null> {
  const day = new Date(now.getTime() + 9 * 3600_000);
  day.setUTCDate(day.getUTCDate() - 1);
  const date = day.toISOString().slice(0, 10);
  const { data, error } = await client.from('task_instances').select('title').eq('household_id', householdId)
    .eq('planned_assignee_id', recipientId).eq('scheduled_date', date).is('test_context_id', null)
    .in('status', ['todo', 'in_progress']).order('due_at', { ascending: true, nullsFirst: false }).limit(80);
  if (error) return null;
  const text = previousDayReminderText(date, (data ?? []).map((task: { title: string }) => task.title));
  return text ? { date, text } : null;
}
