import { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase } from '../../lib/supabaseClient';
import type { TaskInstance } from '../../lib/types';

export interface PlanningEvent {
  id: string;
  date: string;
  time: string | null;
  title: string;
  kind: 'task' | 'calendar';
  assigneeId: string | null;
}

function dateOnly(value: string): string { return value.slice(0, 10); }

export function usePlanningData(householdId: string | null, start: string, end: string) {
  const [tasks, setTasks] = useState<TaskInstance[]>([]);
  const [events, setEvents] = useState<PlanningEvent[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!householdId) { setLoading(false); return; }
    setLoading(true); setError(null);
    try {
      const [{ data: taskRows, error: taskError }, { data: calendarRows, error: calendarError }] = await Promise.all([
        supabase.from('task_instances').select('*').eq('household_id', householdId).gte('scheduled_date', start).lte('scheduled_date', end).neq('status', 'cancelled').order('scheduled_date'),
        supabase.from('calendar_event_occurrences').select('*').eq('household_id', householdId).gte('starts_at', `${start}T00:00:00+09:00`).lt('starts_at', `${end}T23:59:59+09:00`).order('starts_at'),
      ]);
      if (taskError) throw taskError;
      // Calendar is optional (for households that have not connected Google).
      if (calendarError && !/does not exist|permission/i.test(calendarError.message)) throw calendarError;
      setTasks(taskRows ?? []);
      setEvents((calendarRows ?? []).map((row: { occurrence_key: string; starts_at: string; title: string | null }) => ({
        id: row.occurrence_key, date: dateOnly(row.starts_at), time: row.starts_at, title: row.title || '予定', kind: 'calendar', assigneeId: null,
      })));
    } catch (err) { setError(err instanceof Error ? err.message : '予定を読み込めませんでした。'); }
    finally { setLoading(false); }
  }, [end, householdId, start]);

  useEffect(() => { load(); }, [load]);
  const allEvents = useMemo<PlanningEvent[]>(() => [
    ...tasks.map((task) => ({ id: task.id, date: task.scheduled_date, time: task.due_at, title: task.title, kind: 'task' as const, assigneeId: task.planned_assignee_id })),
    ...events,
  ].sort((a, b) => `${a.date}${a.time ?? ''}`.localeCompare(`${b.date}${b.time ?? ''}`)), [events, tasks]);
  return { loading, error, tasks, events: allEvents, refresh: load };
}
