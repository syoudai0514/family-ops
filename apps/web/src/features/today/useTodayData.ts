import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../../lib/supabaseClient';
import { previousTokyoIsoDate, todayIsoDate } from '../../lib/date';
import { useRealtimeRefresh } from '../../lib/useRealtimeRefresh';
import type {
  Handover,
  RequestRow,
  ShoppingItem,
  TaskInstance,
  TaskSubtaskInstance,
} from '../../lib/types';

export interface TaskExecutionTarget {
  id: string;
  household_id: string;
  task_instance_id: string;
  target_kind: 'url' | 'destination';
  label: string | null;
  url: string | null;
  destination: string | null;
  created_at: string;
}

export interface TodayData {
  loading: boolean;
  error: string | null;
  tasks: TaskInstance[];
  carryoverTasks: TaskInstance[];
  subtasksByTaskId: Map<string, TaskSubtaskInstance[]>;
  executionTargetsByTaskId: Map<string, TaskExecutionTarget>;
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

const ACTIVE_TASK_STATUSES = ['todo', 'in_progress'];
const TODAY_TASK_STATUSES = ['todo', 'in_progress', 'completed'];
const OPEN_SHOPPING_STATUSES = ['wanted', 'assigned', 'ordered'];
const HANDOVER_LOOKBACK_DAYS = 7;

function capabilityReaderDisabled(error: { message?: string } | null): boolean {
  return Boolean(error?.message?.includes('CAPABILITY_READER_NOT_ENABLED'));
}

export function useTodayData(householdId: string | null, userId: string | null): TodayData {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tasks, setTasks] = useState<TaskInstance[]>([]);
  const [carryoverTasks, setCarryoverTasks] = useState<TaskInstance[]>([]);
  const [subtasksByTaskId, setSubtasksByTaskId] = useState<Map<string, TaskSubtaskInstance[]>>(new Map());
  const [executionTargetsByTaskId, setExecutionTargetsByTaskId] = useState<Map<string, TaskExecutionTarget>>(new Map());
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

      let taskRows: TaskInstance[] = [];
      let carryoverRows: TaskInstance[] = [];

      if (briefError && capabilityReaderDisabled(briefError)) {
        // R0 is intentionally legacy-read-only. The DB gate rejects the
        // canonical adapter before reading business rows; keep the established
        // Today contract until the separately reviewed P1 gate is crossed.
        const lookbackDate = new Date();
        lookbackDate.setDate(lookbackDate.getDate() - HANDOVER_LOOKBACK_DAYS);

        const [taskRes, carryoverRes, requestRes, handoverRes, shoppingRes] = await Promise.all([
          supabase
            .from('task_instances')
            .select('*')
            .eq('household_id', householdId)
            .eq('scheduled_date', today)
            .in('status', TODAY_TASK_STATUSES)
            .order('due_at', { ascending: true, nullsFirst: false }),
          supabase
            .from('task_instances')
            .select('*')
            .eq('household_id', householdId)
            .eq('task_kind', 'evening_chore')
            .eq('scheduled_date', previousTokyoIsoDate(today))
            .in('status', ACTIVE_TASK_STATUSES)
            .order('scheduled_date', { ascending: false })
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
        if (carryoverRes.error) throw carryoverRes.error;
        if (requestRes.error) throw requestRes.error;
        if (handoverRes.error) throw handoverRes.error;
        if (shoppingRes.error) throw shoppingRes.error;

        taskRows = taskRes.data ?? [];
        carryoverRows = (carryoverRes.data ?? []).filter(
          (task) => task.task_kind === 'evening_chore' && task.scheduled_date === previousTokyoIsoDate(today),
        );
        setTasks(taskRows);
        setCarryoverTasks(carryoverRows);
        setIncomingRequests(requestRes.data ?? []);
        setOpenShoppingItems(shoppingRes.data ?? []);
        setBriefSchedule([]);

        const handovers = handoverRes.data ?? [];
        if (handovers.length > 0) {
          const { data: readRows, error: readError } = await supabase
            .from('handover_reads')
            .select('handover_id')
            .eq('user_id', userId)
            .in('handover_id', handovers.map((handover) => handover.id));
          if (readError) throw readError;
          const readIds = new Set((readRows ?? []).map((row) => row.handover_id));
          setUnreadHandovers(handovers.filter((handover) => !readIds.has(handover.id)));
        } else {
          setUnreadHandovers([]);
        }
      } else {
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

        taskRows = taskRes.data ?? [];
        carryoverRows = carryoverRes.data ?? [];
        setTasks(taskRows);
        setCarryoverTasks(carryoverRows);
        setIncomingRequests(requestRes.data ?? []);
        setOpenShoppingItems(shoppingRes.data ?? []);
        setUnreadHandovers(handoverRes.data ?? []);
        setBriefSchedule(brief.schedule ?? []);
      }

      const visibleTaskIds = [...new Set([...taskRows, ...carryoverRows].map((task) => task.id))];
      const subtaskModeTaskIds = [...taskRows, ...carryoverRows]
        .filter((task) => task.completion_mode === 'subtasks')
        .map((task) => task.id);

      const [subtaskResult, targetResult] = await Promise.all([
        subtaskModeTaskIds.length > 0
          ? supabase
              .from('task_subtask_instances')
              .select('*')
              .in('task_instance_id', subtaskModeTaskIds)
              .order('sort_order', { ascending: true })
          : Promise.resolve({ data: [] as TaskSubtaskInstance[], error: null }),
        visibleTaskIds.length > 0
          ? supabase
              .from('task_execution_targets')
              .select('*')
              .eq('household_id', householdId)
              .in('task_instance_id', visibleTaskIds)
          : Promise.resolve({ data: [] as TaskExecutionTarget[], error: null }),
      ]);

      if (subtaskResult.error) throw subtaskResult.error;
      if (targetResult.error) throw targetResult.error;

      const groupedSubtasks = new Map<string, TaskSubtaskInstance[]>();
      for (const row of subtaskResult.data ?? []) {
        const list = groupedSubtasks.get(row.task_instance_id) ?? [];
        list.push(row);
        groupedSubtasks.set(row.task_instance_id, list);
      }
      setSubtasksByTaskId(groupedSubtasks);

      const targetMap = new Map<string, TaskExecutionTarget>();
      for (const row of targetResult.data ?? []) targetMap.set(row.task_instance_id, row as TaskExecutionTarget);
      setExecutionTargetsByTaskId(targetMap);
    } catch (err) {
      setError(err instanceof Error ? err.message : '読み込みに失敗しました。');
    } finally {
      setLoading(false);
    }
  }, [householdId, userId]);

  useEffect(() => {
    load();
  }, [load]);

  useRealtimeRefresh({ householdId, userId, onRemoteChange: load });

  return {
    loading,
    error,
    tasks,
    carryoverTasks,
    subtasksByTaskId,
    executionTargetsByTaskId,
    incomingRequests,
    unreadHandovers,
    openShoppingItems,
    briefSchedule,
    refresh: load,
  };
}