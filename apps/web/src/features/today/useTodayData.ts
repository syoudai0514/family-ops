import { useCallback, useEffect, useRef, useState } from 'react';
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

export type TodayTaskInstance = TaskInstance & {
  execution_target?: TaskExecutionTarget | null;
};

export type TodayLoadState = 'loading' | 'ready' | 'empty' | 'stale' | 'error';

export interface TodayRequestAttempt {
  id: string;
  request_id: string;
  state: 'pending' | 'checking' | 'consulting' | 'awaiting_confirmation' | 'accepted' | 'declined' | 'expired' | 'cancelled';
  revision: number;
  terms_revision: number;
  reply_due_at: string | null;
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

interface TodaySnapshot {
  tasks: TodayTaskInstance[];
  carryoverTasks: TodayTaskInstance[];
  alreadyHandledTasks: TodayTaskInstance[];
  subtasksByTaskId: Map<string, TaskSubtaskInstance[]>;
  executionTargetsByTaskId: Map<string, TaskExecutionTarget>;
  incomingRequests: RequestRow[];
  requestAttemptsByRequestId: Map<string, TodayRequestAttempt>;
  unreadHandovers: Handover[];
  openShoppingItems: ShoppingItem[];
  briefSchedule: DailyBriefScheduleItem[];
}

export interface TodayData extends TodaySnapshot {
  status: TodayLoadState;
  loading: boolean;
  refreshing: boolean;
  error: string | null;
  lastUpdatedAt: number | null;
  refresh: () => Promise<void>;
}

const EMPTY_SNAPSHOT: TodaySnapshot = {
  tasks: [],
  carryoverTasks: [],
  alreadyHandledTasks: [],
  subtasksByTaskId: new Map(),
  executionTargetsByTaskId: new Map(),
  incomingRequests: [],
  requestAttemptsByRequestId: new Map(),
  unreadHandovers: [],
  openShoppingItems: [],
  briefSchedule: [],
};

function isSnapshotEmpty(snapshot: TodaySnapshot) {
  return snapshot.tasks.length === 0
    && snapshot.carryoverTasks.length === 0
    && snapshot.alreadyHandledTasks.length === 0
    && snapshot.incomingRequests.length === 0
    && snapshot.unreadHandovers.length === 0
    && snapshot.openShoppingItems.length === 0
    && snapshot.briefSchedule.length === 0;
}

function unique(values: Array<string | undefined>) {
  return [...new Set(values.filter((value): value is string => Boolean(value)))];
}

export function useTodayData(householdId: string | null, userId: string | null): TodayData {
  const [snapshot, setSnapshot] = useState<TodaySnapshot>(EMPTY_SNAPSHOT);
  const [status, setStatus] = useState<TodayLoadState>('loading');
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [lastUpdatedAt, setLastUpdatedAt] = useState<number | null>(null);
  const hasSuccessfulSnapshot = useRef(false);
  const requestSequence = useRef(0);

  const load = useCallback(async () => {
    const sequence = ++requestSequence.current;
    if (!householdId || !userId) {
      if (sequence === requestSequence.current) {
        setSnapshot(EMPTY_SNAPSHOT);
        setStatus('empty');
        setRefreshing(false);
        setError(null);
      }
      return;
    }

    if (hasSuccessfulSnapshot.current) setRefreshing(true);
    else setStatus('loading');
    setError(null);

    try {
      const { data: briefData, error: briefError } = await supabase.rpc('get_my_daily_brief', {
        p_local_date: todayIsoDate(),
      });
      if (briefError) throw briefError;
      const brief = (briefData ?? {}) as DailyBriefPayload;

      const taskIds = unique((brief.tasks ?? []).map((item) => item.task_id));
      const carryoverIds = unique((brief.carryover ?? []).map((item) => item.task_id));
      const handledIds = unique((brief.already_handled ?? []).map((item) => item.task_id));
      const allTaskIds = unique([...taskIds, ...carryoverIds, ...handledIds]);
      const requestIds = unique((brief.urgent_actions ?? []).map((item) => item.request_id));
      const handoverIds = unique((brief.handovers ?? []).map((item) => item.handover_id));
      const shoppingIds = unique((brief.shopping ?? []).map((item) => item.shopping_item_id));

      const [taskRes, requestRes, attemptRes, handoverRes, shoppingRes] = await Promise.all([
        allTaskIds.length
          ? supabase.from('task_instances').select('*').in('id', allTaskIds)
          : Promise.resolve({ data: [] as TodayTaskInstance[], error: null }),
        requestIds.length
          ? supabase.from('requests').select('*').in('id', requestIds).order('due_at', { ascending: true, nullsFirst: false })
          : Promise.resolve({ data: [] as RequestRow[], error: null }),
        requestIds.length
          ? supabase.from('request_attempts')
              .select('id, request_id, state, revision, terms_revision, reply_due_at, created_at')
              .in('request_id', requestIds)
              .is('test_context_id', null)
              .order('created_at', { ascending: false })
          : Promise.resolve({ data: [] as TodayRequestAttempt[], error: null }),
        handoverIds.length
          ? supabase.from('handovers').select('*').in('id', handoverIds).order('created_at', { ascending: false })
          : Promise.resolve({ data: [] as Handover[], error: null }),
        shoppingIds.length
          ? supabase.from('shopping_items').select('*').in('id', shoppingIds).order('due_at', { ascending: true, nullsFirst: false })
          : Promise.resolve({ data: [] as ShoppingItem[], error: null }),
      ]);

      for (const result of [taskRes, requestRes, attemptRes, handoverRes, shoppingRes]) {
        if (result.error) throw result.error;
      }

      const taskById = new Map(((taskRes.data ?? []) as TodayTaskInstance[]).map((task) => [task.id, task]));
      const latestAttemptByRequestId = new Map<string, TodayRequestAttempt>();
      for (const attempt of (attemptRes.data ?? []) as TodayRequestAttempt[]) {
        if (!latestAttemptByRequestId.has(attempt.request_id)) latestAttemptByRequestId.set(attempt.request_id, attempt);
      }

      const visibleTasks = unique([...taskIds, ...carryoverIds, ...handledIds])
        .map((id) => taskById.get(id))
        .filter((task): task is TodayTaskInstance => Boolean(task));
      const subtaskTaskIds = visibleTasks.filter((task) => task.completion_mode === 'subtasks').map((task) => task.id);

      const [subtaskRes, targetRes] = await Promise.all([
        subtaskTaskIds.length
          ? supabase.from('task_subtask_instances').select('*').in('task_instance_id', subtaskTaskIds).order('sort_order', { ascending: true })
          : Promise.resolve({ data: [] as TaskSubtaskInstance[], error: null }),
        visibleTasks.length
          ? supabase.from('task_execution_targets').select('*').eq('household_id', householdId).in('task_instance_id', visibleTasks.map((task) => task.id))
          : Promise.resolve({ data: [] as TaskExecutionTarget[], error: null }),
      ]);
      if (subtaskRes.error) throw subtaskRes.error;
      if (targetRes.error) throw targetRes.error;

      const groupedSubtasks = new Map<string, TaskSubtaskInstance[]>();
      for (const row of subtaskRes.data ?? []) {
        const current = groupedSubtasks.get(row.task_instance_id) ?? [];
        current.push(row);
        groupedSubtasks.set(row.task_instance_id, current);
      }
      const targetMap = new Map<string, TaskExecutionTarget>();
      for (const row of targetRes.data ?? []) targetMap.set(row.task_instance_id, row as TaskExecutionTarget);
      const hydrate = (ids: string[]) => ids
        .map((id) => taskById.get(id))
        .filter((task): task is TodayTaskInstance => Boolean(task))
        .map((task) => ({ ...task, execution_target: targetMap.get(task.id) ?? null }));

      const nextSnapshot: TodaySnapshot = {
        tasks: hydrate(taskIds),
        carryoverTasks: hydrate(carryoverIds),
        alreadyHandledTasks: hydrate(handledIds),
        subtasksByTaskId: groupedSubtasks,
        executionTargetsByTaskId: targetMap,
        incomingRequests: (requestRes.data ?? []) as RequestRow[],
        requestAttemptsByRequestId: latestAttemptByRequestId,
        unreadHandovers: (handoverRes.data ?? []) as Handover[],
        openShoppingItems: (shoppingRes.data ?? []) as ShoppingItem[],
        briefSchedule: brief.schedule ?? [],
      };

      if (sequence !== requestSequence.current) return;
      setSnapshot(nextSnapshot);
      hasSuccessfulSnapshot.current = true;
      setStatus(isSnapshotEmpty(nextSnapshot) ? 'empty' : 'ready');
      setLastUpdatedAt(Date.now());
      setError(null);
    } catch (err) {
      if (sequence !== requestSequence.current) return;
      setError(err instanceof Error ? err.message : '読み込みに失敗しました。');
      setStatus(hasSuccessfulSnapshot.current ? 'stale' : 'error');
    } finally {
      if (sequence === requestSequence.current) setRefreshing(false);
    }
  }, [householdId, userId]);

  useEffect(() => {
    hasSuccessfulSnapshot.current = false;
    setSnapshot(EMPTY_SNAPSHOT);
    setLastUpdatedAt(null);
    void load();
  }, [load]);

  useRealtimeRefresh({ householdId, userId, onRemoteChange: load });

  return {
    ...snapshot,
    status,
    loading: status === 'loading',
    refreshing,
    error,
    lastUpdatedAt,
    refresh: load,
  };
}
