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
  carryoverTasks: TaskInstance[];
  subtasksByTaskId: Map<string, TaskSubtaskInstance[]>;
  incomingRequests: RequestRow[];
  unreadHandovers: Handover[];
  openShoppingItems: ShoppingItem[];
  briefSchedule: DailyBriefScheduleItem[];
  refresh: () => Promise<void>;
}

export interface DailyBriefScheduleItem {
  kind: 'family_event' | 'google_occurrence';
  family_event_id?: string;
  occurrence_key?: string;
  title: string | null;
  is_all_day: boolean;
  starts_at: string | null;
  ends_at: string | null;
  all_day_start: string | null;
  all_day_end_exclusive: string | null;
}

interface DailyBriefPayload {
  tasks?: Array<{ task_id: string }>;
  carryover?: Array<{ task_id: string }>;
  already_handled?: Array<{ task_id?: string }>;
  urgent_actions?: Array<{ request_id: string }>;
  handovers?: Array<{ handover_id: string }>;
  shopping?: Array<{ shopping_item_id: string }>;
  schedule?: DailyBriefScheduleItem[];
}

export function useTodayData(householdId: string | null, userId: string | null): TodayData {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tasks, setTasks] = useState<TaskInstance[]>([]);
  const [carryoverTasks, setCarryoverTasks] = useState<TaskInstance[]>([]);
  const [subtasksByTaskId, setSubtasksByTaskId] = useState<Map<string, TaskSubtaskInstance[]>>(new Map());
  const [incomingRequests, setIncomingRequests] = useState<RequestRow[]>([]);
  const [unreadHandovers, setUnreadHandovers] = useState<Handover[]>([]);
  const [openShoppingItems, setOpenShoppingItems] = useState<ShoppingItem[]>([]);
  const [briefSchedule, setBriefSchedule] = useState<DailyBriefScheduleItem[]>([]);

  const load = useCallback(async () => {
    if (!householdId || !userId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);

    try {
      const today = todayIsoDate();
      const { data: briefData, error: briefError } = await supabase.rpc('get_my_daily_brief', {
        p_local_date: today,
      });
      if (briefError) throw briefError;
      const brief = (briefData ?? {}) as DailyBriefPayload;
      const taskIds = [...new Set([
        ...(brief.tasks ?? []).map((item) => item.task_id),
        ...(brief.already_handled ?? []).flatMap((item) => item.task_id ? [item.task_id] : []),
      ])];
      const carryoverIds = [...new Set((brief.carryover ?? []).map((item) => item.task_id))];
      const requestIds = [...new Set((brief.urgent_actions ?? []).map((item) => item.request_id))];
      const handoverIds = [...new Set((brief.handovers ?? []).map((item) => item.handover_id))];
      const shoppingIds = [...new Set((brief.shopping ?? []).map((item) => item.shopping_item_id))];

      const [taskRes, carryoverRes, requestRes, handoverRes, shoppingRes] = await Promise.all([
        taskIds.length > 0
          ? supabase.from('task_instances').select('*').in('id', taskIds).order('due_at', { ascending: true, nullsFirst: false })
          : Promise.resolve({ data: [] as TaskInstance[], error: null }),
        carryoverIds.length > 0
          ? supabase.from('task_instances').select('*').in('id', carryoverIds).order('due_at', { ascending: true, nullsFirst: false })
          : Promise.resolve({ data: [] as TaskInstance[], error: null }),
        requestIds.length > 0
          ? supabase.from('requests').select('*').in('id', requestIds).order('due_at', { ascending: true, nullsFirst: false })
          : Promise.resolve({ data: [] as RequestRow[], error: null }),
        handoverIds.length > 0
          ? supabase.from('handovers').select('*').in('id', handoverIds).order('created_at', { ascending: false })
          : Promise.resolve({ data: [] as Handover[], error: null }),
        shoppingIds.length > 0
          ? supabase.from('shopping_items').select('*').in('id', shoppingIds).order('due_at', { ascending: true, nullsFirst: false })
          : Promise.resolve({ data: [] as ShoppingItem[], error: null }),
      ]);

      if (taskRes.error) throw taskRes.error;
      if (carryoverRes.error) throw carryoverRes.error;
      if (requestRes.error) throw requestRes.error;
      if (handoverRes.error) throw handoverRes.error;
      if (shoppingRes.error) throw shoppingRes.error;

      const taskRows = taskRes.data ?? [];
      setTasks(taskRows);
      setCarryoverTasks(carryoverRes.data ?? []);
      setIncomingRequests(requestRes.data ?? []);
      setOpenShoppingItems(shoppingRes.data ?? []);
      setBriefSchedule(brief.schedule ?? []);

      const subtaskModeTaskIds = [...taskRows, ...(carryoverRes.data ?? [])]
        .filter((t) => t.completion_mode === 'subtasks')
        .map((t) => t.id);
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

      setUnreadHandovers(handoverRes.data ?? []);
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
    carryoverTasks,
    subtasksByTaskId,
    incomingRequests,
    unreadHandovers,
    openShoppingItems,
    briefSchedule,
    refresh: load,
  };
}
