import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase } from '../../lib/supabaseClient';
import { useRealtimeRefresh } from '../../lib/useRealtimeRefresh';
import { withTimeout } from '../../lib/withTimeout';
import { summarizeTaskRecording, type RecordingTask } from '../tasks/taskRecording';

const TABLES = ['task_instances'];

export function useDayTaskRecording(householdId: string | null, date: string) {
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
          .select('scheduled_date,status,outcome_reason')
          .eq('household_id', householdId)
          .eq('scheduled_date', date),
        12_000,
        '記録状況を取得できませんでした。',
      );
      if (error) throw error;
      if (attempt === sequence.current)
        setSnapshot({ key, tasks: (data ?? []) as RecordingTask[], error: false });
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
    summary: current && !current.error ? summarizeTaskRecording(current.tasks, date) : null,
    error: current?.error ?? false,
    refresh,
  };
}
