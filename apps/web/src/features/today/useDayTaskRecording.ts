import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase } from '../../lib/supabaseClient';
import { useRealtimeRefresh } from '../../lib/useRealtimeRefresh';
import { withTimeout } from '../../lib/withTimeout';
import { withClaimantUsers } from '../../lib/claimantUsers';
import { summarizeTaskRecording, type RecordingTask } from '../tasks/taskRecording';

const TABLES = ['task_instances'];

export function useDayTaskRecording(householdId: string | null, date: string, userId: string | null = null) {
  const key = `${householdId}:${date}`;
  const [snapshot, setSnapshot] = useState<{
    key: string;
    tasks: RecordingTask[];
    error: boolean;
  } | null>(null);
  const sequence = useRef(0);
  const refresh = useCallback(async () => {
    const attempt = ++sequence.current;
    if (!householdId) return;
    try {
      const { data, error } = await withTimeout(
        supabase
          .from('task_instances')
          .select('scheduled_date,status,outcome_reason,planned_assignee_id,assignment_mode,active_claimant_actor_ref_id,expectation')
          .eq('household_id', householdId)
          .eq('scheduled_date', date),
        12_000,
        '記録状況を取得できませんでした。',
      );
      if (error) throw error;
      const tasks = await withClaimantUsers(householdId, (data ?? []) as Array<RecordingTask & { active_claimant_actor_ref_id?: string | null }>);
      if (attempt === sequence.current)
        setSnapshot({ key, tasks, error: false });
    } catch {
      if (attempt === sequence.current) setSnapshot({ key, tasks: [], error: true });
    }
  }, [householdId, date, key]);
  useEffect(() => {
    void refresh();
    const onVisible = () => {
      if (document.visibilityState === 'visible') void refresh();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      sequence.current++;
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [refresh]);
  useRealtimeRefresh({ householdId, userId: null, tables: TABLES, onRemoteChange: refresh });
  const current = snapshot?.key === key ? snapshot : null;
  return {
    summary: current && !current.error ? summarizeTaskRecording(current.tasks, date, { userId }) : null,
    error: current?.error ?? false,
    refresh,
  };
}
