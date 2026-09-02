import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../../lib/supabaseClient';
import { useRealtimeRefresh } from '../../lib/useRealtimeRefresh';
import type { TaskEvent, TaskInstance } from '../../lib/types';

// WP-DD5 — planned vs actual history. Shows recently-scheduled tasks alongside
// what actually happened. Canonical outcome_reason is current snapshot truth,
// so 「今回は不要」 and 「できなかった」 are distinguishable without replaying
// audit events. Legacy skipped rows with unknown reason stay explicitly generic
// rather than being guessed into either semantic bucket.
const HISTORY_WINDOW_DAYS = 14;
const HISTORY_REALTIME_TABLES = ['task_instances', 'task_events'];

export type PlannedVsActualOutcome =
  | 'completed_on_time'
  | 'completed_late'
  | 'not_needed'
  | 'could_not_do'
  | 'expired_occurrence'
  | 'skipped'
  | 'cancelled'
  | 'waiting'
  | 'overdue_open'
  | 'in_progress'
  | 'upcoming';

export interface HistoryEntry {
  task: TaskInstance;
  outcome: PlannedVsActualOutcome;
  events: TaskEvent[];
  /** True if a `reassigned_once` event exists for this task. */
  wasReassigned: boolean;
}

export interface HistoryData {
  loading: boolean;
  error: string | null;
  entries: HistoryEntry[];
  refresh: () => Promise<void>;
}

function windowStartDate(): string {
  const d = new Date();
  d.setDate(d.getDate() - HISTORY_WINDOW_DAYS);
  return d.toISOString().slice(0, 10);
}

export function classifyOutcome(task: TaskInstance, nowIso: string): PlannedVsActualOutcome {
  if (task.status === 'completed') {
    if (task.due_at && task.completed_at && task.completed_at > task.due_at) {
      return 'completed_late';
    }
    return 'completed_on_time';
  }
  if (task.status === 'skipped') {
    if (task.outcome_reason === 'not_needed_this_occurrence') return 'not_needed';
    if (task.outcome_reason === 'could_not_do') return 'could_not_do';
    if (task.outcome_reason === 'expired_occurrence') return 'expired_occurrence';
    return 'skipped';
  }
  if (task.status === 'cancelled') return 'cancelled';
  // waiting is an orthogonal attention dimension, not completion/failure.
  // It must never be rendered as an overdue failure merely because due_at
  // passed while the household is intentionally waiting on an external event.
  if (task.attention_state === 'waiting') return 'waiting';
  if (task.status === 'in_progress') return 'in_progress';
  // status === 'todo'
  if (task.due_at && task.due_at < nowIso) return 'overdue_open';
  return 'upcoming';
}

export function useHistoryData(householdId: string | null, userId: string | null): HistoryData {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [entries, setEntries] = useState<HistoryEntry[]>([]);

  const load = useCallback(async () => {
    if (!householdId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const startDate = windowStartDate();
      const nowIso = new Date().toISOString();

      const { data: taskRows, error: taskError } = await supabase
        .from('task_instances')
        .select('*')
        .eq('household_id', householdId)
        .gte('scheduled_date', startDate)
        .order('scheduled_date', { ascending: false })
        .order('due_at', { ascending: false, nullsFirst: false });
      if (taskError) throw taskError;

      // RLS on task_instances excludes test_context_id rows from ordinary
      // production History. Keep the client-side guard too so a future RLS
      // regression cannot silently blend simulation data into household facts.
      const tasks: TaskInstance[] = (taskRows ?? []).filter((task) => !task.test_context_id);
      const taskIds = tasks.map((t) => t.id);

      let eventsByTaskId = new Map<string, TaskEvent[]>();
      if (taskIds.length > 0) {
        const { data: eventRows, error: eventError } = await supabase
          .from('task_events')
          .select('*')
          .eq('household_id', householdId)
          .in('task_instance_id', taskIds)
          .order('created_at', { ascending: true });
        if (eventError) throw eventError;
        const grouped = new Map<string, TaskEvent[]>();
        for (const row of (eventRows ?? []) as TaskEvent[]) {
          const list = grouped.get(row.task_instance_id) ?? [];
          list.push(row);
          grouped.set(row.task_instance_id, list);
        }
        eventsByTaskId = grouped;
      }

      const nextEntries: HistoryEntry[] = tasks.map((task) => {
        const events = eventsByTaskId.get(task.id) ?? [];
        return {
          task,
          outcome: classifyOutcome(task, nowIso),
          events,
          wasReassigned: events.some((e) => e.event_type === 'reassigned_once'),
        };
      });
      setEntries(nextEntries);
    } catch (err) {
      setError(err instanceof Error ? err.message : '読み込みに失敗しました。');
    } finally {
      setLoading(false);
    }
  }, [householdId]);

  useEffect(() => {
    load();
  }, [load]);

  useRealtimeRefresh({ householdId, userId, onRemoteChange: load, tables: HISTORY_REALTIME_TABLES });

  return { loading, error, entries, refresh: load };
}
