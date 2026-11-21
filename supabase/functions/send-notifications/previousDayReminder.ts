import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

export async function loadPreviousDayReminder(client: SupabaseClient, householdId: string, recipientId: string, now = new Date()): Promise<{ date: string; text: string } | null> {
  const since = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000).toISOString();
  const { data: recordings, error: recordingError } = await client.from('task_events')
    .select('id').eq('household_id', householdId).eq('actor_id', recipientId)
    .is('test_context_id', null).gte('created_at', since)
    .in('event_type', ['completed', 'skipped', 'subtask_completed', 'work_progress_recorded']).limit(1);
  if (recordingError || !recordings?.length) return null;

  const day = new Date(now.getTime() + 9 * 3600_000);
  day.setUTCDate(day.getUTCDate() - 1);
  const date = day.toISOString().slice(0, 10);
  const { data, error } = await client.from('task_instances').select('id').eq('household_id', householdId)
    .eq('planned_assignee_id', recipientId).eq('scheduled_date', date).is('test_context_id', null)
    .in('status', ['todo', 'in_progress']).limit(1);
  return !error && data?.length ? { date, text: '昨日の分、まとめて済みにしますか？' } : null;
}
