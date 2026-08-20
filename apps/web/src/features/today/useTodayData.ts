import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../../lib/supabaseClient';
import { todayIsoDate } from '../../lib/date';
import { useRealtimeRefresh } from '../../lib/useRealtimeRefresh';
import type {
  Handover,
  RequestRow,
  ShoppingItem,
  TaskInstance,
  TaskSubtaskInstance,
} from '../../lib/types';

export interface TodayData {
  loading: boolean;
  error: string | null;
  tasks: TaskInstance[];
  subtasksByTaskId: Map<string, TaskSubtaskInstance[]>;
  incomingRequests: RequestRow[];
  unreadHandovers: Handover[];
  openShoppingItems: ShoppingItem[];
  refresh: () => Promise<void>;
}

const ACTIVE_TASK_STATUSES = ['todo', 'in_progress'];
const OPEN_SHOPPING_STATUSES = ['wanted', 'assigned', 'ordered'];
// Handovers older than this are excluded from the unread-scan, matching the
// "Today" screen's day-to-day scope — old unread handovers are still
// reachable from the full Handovers screen, they just don't clutter Today.
const HANDOVER_LOOKBACK_DAYS = 7;

export function useTodayData(householdId: string | null, userId: string | null): TodayData {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tasks, setTasks] = useState<TaskInstance[]>([]);
  const [subtasksByTaskId, setSubtasksByTaskId] = useState<Map<string, TaskSubtaskInstance[]>>(new Map());
  const [incomingRequests, setIncomingRequests] = useState<RequestRow[]>([]);
  const [unreadHandovers, setUnreadHandovers] = useState<Handover[]>([]);
  const [openShoppingItems, setOpenShoppingItems] = useState<ShoppingItem[]>([]);

  const load = useCallback(async () => {
    if (!householdId || !userId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);

    try {
      const today = todayIsoDate();
      const lookbackDate = new Date();
      lookbackDate.setDate(lookbackDate.getDate() - HANDOVER_LOOKBACK_DAYS);

      const [taskRes, requestRes, handoverRes, shoppingRes] = await Promise.all([
        supabase
          .from('task_instances')
          .select('*')
          .eq('household_id', householdId)
          .eq('scheduled_date', today)
          .in('status', ACTIVE_TASK_STATUSES)
          .order('due_at', { ascending: true, nullsFirst: false }),
        supabase
          .from('requests')
          .select('*')
          .eq('household_id', householdId)
          .eq('recipient_id', userId)
          .eq('status', 'pending')
          .order('due_at', { ascending: true, nullsFirst: false }),
        supabase
          .from('handovers')
          .select('*')
          .eq('household_id', householdId)
          .gte('occurred_on', lookbackDate.toISOString().slice(0, 10))
          .order('created_at', { ascending: false }),
        supabase
          .from('shopping_items')
          .select('*')
          .eq('household_id', householdId)
          .in('status', OPEN_SHOPPING_STATUSES)
          .order('due_at', { ascending: true, nullsFirst: false }),
      ]);

      if (taskRes.error) throw taskRes.error;
      if (requestRes.error) throw requestRes.error;
      if (handoverRes.error) throw handoverRes.error;
      if (shoppingRes.error) throw shoppingRes.error;

      const taskRows = taskRes.data ?? [];
      setTasks(taskRows);
      setIncomingRequests(requestRes.data ?? []);
      setOpenShoppingItems(shoppingRes.data ?? []);

      const subtaskModeTaskIds = taskRows.filter((t) => t.completion_mode === 'subtasks').map((t) => t.id);
      if (subtaskModeTaskIds.length > 0) {
        const { data: subtaskRows, error: subtaskError } = await supabase
          .from('task_subtask_instances')
          .select('*')
          .in('task_instance_id', subtaskModeTaskIds)
          .order('sort_order', { ascending: true });
        if (subtaskError) throw subtaskError;
        const grouped = new Map<string, TaskSubtaskInstance[]>();
        for (const row of subtaskRows ?? []) {
          const list = grouped.get(row.task_instance_id) ?? [];
          list.push(row);
          grouped.set(row.task_instance_id, list);
        }
        setSubtasksByTaskId(grouped);
      } else {
        setSubtasksByTaskId(new Map());
      }

      const handovers = handoverRes.data ?? [];
      if (handovers.length > 0) {
        const { data: readRows, error: readError } = await supabase
          .from('handover_reads')
          .select('handover_id')
          .eq('user_id', userId)
          .in(
            'handover_id',
            handovers.map((h) => h.id),
          );
        if (readError) throw readError;
        const readIds = new Set((readRows ?? []).map((r) => r.handover_id));
        setUnreadHandovers(handovers.filter((h) => !readIds.has(h.id)));
      } else {
        setUnreadHandovers([]);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : '読み込みに失敗しました。');
    } finally {
      setLoading(false);
    }
  }, [householdId, userId]);

  useEffect(() => {
    load();
  }, [load]);

  // WP4 — Today refresh after partner mutation: whenever the household's
  // tasks/requests/handovers/shopping change (typically the other member
  // acting from their own device), re-run the same load() this screen
  // already uses for its own mutations and initial load. No full-page
  // reload; React just re-renders with fresher data.
  useRealtimeRefresh({ householdId, userId, onRemoteChange: load });

  return {
    loading,
    error,
    tasks,
    subtasksByTaskId,
    incomingRequests,
    unreadHandovers,
    openShoppingItems,
    refresh: load,
  };
}
