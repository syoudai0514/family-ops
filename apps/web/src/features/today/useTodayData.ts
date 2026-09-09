import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase } from '../../lib/supabaseClient';
import { useRealtimeRefresh } from '../../lib/useRealtimeRefresh';
import type {
  Handover,
  RequestRow,
  ShoppingItem,
  TaskInstance,
  TaskSubtaskInstance,
} from '../../lib/types';
import { tokyoLocalDate } from './todayClock';

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

export interface DailyBriefAction {
  kind?: string;
  request_id?: string;
  attempt_id?: string;
  attempt_kind?: string;
  state?: TodayRequestAttempt['state'];
  title?: string | null;
  message?: string | null;
  task_id?: string;
  revision?: number;
  request_revision?: number;
  terms_revision?: number;
  reply_due_at?: string | null;
  due_at?: string | null;
  agreement_established?: boolean;
}

export interface DailyBriefException {
  kind?: string;
  title?: string | null;
  message?: string | null;
  detail?: string | null;
  task_id?: string;
  event_id?: string;
}

export interface DailyBriefWaitingRef {
  task_id: string;
  waiting_note?: string | null;
  next_check_at?: string | null;
  hard_due_at?: string | null;
  hard_due_risk?: boolean;
}

interface DailyBriefTaskRef {
  task_id: string;
  title?: string | null;
  due_at?: string | null;
}

interface DailyBriefTaskGroups {
  morning?: DailyBriefTaskRef[];
  daytime?: DailyBriefTaskRef[];
  evening?: DailyBriefTaskRef[];
  optional?: DailyBriefTaskRef[];
}

export interface DailyBriefPartnerCriticalItem {
  task_id: string;
  title: string;
  task_kind?: string;
  due_at?: string | null;
  revision?: number;
}

export interface DailyBriefPartnerSummary {
  open_assigned?: number;
  waiting?: number;
  completed_today?: number;
  critical_items?: DailyBriefPartnerCriticalItem[];
}

export interface DailyBriefReconciliation {
  sessions: Array<{
    session_id?: string;
    session_type?: string;
    status?: string;
    remaining_count?: number;
  }>;
  remaining_count: number;
  actionable: boolean;
}

export interface DailyBriefTomorrowImpact {
  local_date?: string;
  task_count: number;
  schedule_count: number;
  carryover_count: number;
  impact_count: number;
  tasks: DailyBriefTaskRef[];
  schedule: DailyBriefScheduleItem[];
  carryovers: DailyBriefTaskRef[];
}

export interface DailyBriefMorningSummary {
  completedCount: number;
  totalCount: number;
}

interface DailyBriefMorningSummaryPayload {
  completed_count?: number;
  total_count?: number;
}

interface DailyBriefPayload {
  tasks?: DailyBriefTaskRef[];
  carryover?: DailyBriefTaskRef[];
  carryovers?: DailyBriefTaskRef[];
  already_handled?: DailyBriefTaskRef[];
  urgent_actions?: DailyBriefAction[];
  exceptions?: DailyBriefException[];
  waiting_checks?: DailyBriefWaitingRef[];
  handovers?: Array<{ handover_id: string }>;
  active_infos?: Array<{ handover_id: string }>;
  shopping?: Array<{ shopping_item_id: string }>;
  schedule?: DailyBriefScheduleItem[];
  own_task_groups?: DailyBriefTaskGroups;
  partner_summary?: DailyBriefPartnerSummary;
  reconciliation?: DailyBriefReconciliation;
  tomorrow_impact?: DailyBriefTomorrowImpact;
  morning_summary?: DailyBriefMorningSummaryPayload;
}

export interface TodayTaskGroups {
  morning: TodayTaskInstance[];
  daytime: TodayTaskInstance[];
  evening: TodayTaskInstance[];
  optional: TodayTaskInstance[];
}

interface TodaySnapshot {
  urgentActions: DailyBriefAction[];
  exceptions: DailyBriefException[];
  tasks: TodayTaskInstance[];
  taskGroups: TodayTaskGroups;
  waitingTasks: TodayTaskInstance[];
  waitingRefsByTaskId: Map<string, DailyBriefWaitingRef>;
  carryoverTasks: TodayTaskInstance[];
  alreadyHandledTasks: TodayTaskInstance[];
  subtasksByTaskId: Map<string, TaskSubtaskInstance[]>;
  executionTargetsByTaskId: Map<string, TaskExecutionTarget>;
  incomingRequests: RequestRow[];
  requestAttemptsByRequestId: Map<string, TodayRequestAttempt>;
  unreadHandovers: Handover[];
  openShoppingItems: ShoppingItem[];
  briefSchedule: DailyBriefScheduleItem[];
  partnerSummary: DailyBriefPartnerSummary;
  reconciliation: DailyBriefReconciliation;
  tomorrowImpact: DailyBriefTomorrowImpact;
  morningSummary: DailyBriefMorningSummary;
}

export interface TodayData extends TodaySnapshot {
  status: TodayLoadState;
  loading: boolean;
  refreshing: boolean;
  error: string | null;
  lastUpdatedAt: number | null;
  refresh: () => Promise<void>;
}

const EMPTY_GROUPS: TodayTaskGroups = { morning: [], daytime: [], evening: [], optional: [] };
const EMPTY_RECONCILIATION: DailyBriefReconciliation = { sessions: [], remaining_count: 0, actionable: false };
const EMPTY_TOMORROW: DailyBriefTomorrowImpact = {
  task_count: 0,
  schedule_count: 0,
  carryover_count: 0,
  impact_count: 0,
  tasks: [],
  schedule: [],
  carryovers: [],
};
const EMPTY_MORNING_SUMMARY: DailyBriefMorningSummary = { completedCount: 0, totalCount: 0 };

function emptySnapshot(): TodaySnapshot {
  return {
    urgentActions: [],
    exceptions: [],
    tasks: [],
    taskGroups: EMPTY_GROUPS,
    waitingTasks: [],
    waitingRefsByTaskId: new Map(),
    carryoverTasks: [],
    alreadyHandledTasks: [],
    subtasksByTaskId: new Map(),
    executionTargetsByTaskId: new Map(),
    incomingRequests: [],
    requestAttemptsByRequestId: new Map(),
    unreadHandovers: [],
    openShoppingItems: [],
    briefSchedule: [],
    partnerSummary: {},
    reconciliation: EMPTY_RECONCILIATION,
    tomorrowImpact: EMPTY_TOMORROW,
    morningSummary: EMPTY_MORNING_SUMMARY,
  };
}

function isSnapshotEmpty(snapshot: TodaySnapshot) {
  return snapshot.urgentActions.length === 0
    && snapshot.exceptions.length === 0
    && snapshot.tasks.length === 0
    && snapshot.waitingTasks.length === 0
    && snapshot.carryoverTasks.length === 0
    && snapshot.alreadyHandledTasks.length === 0
    && snapshot.incomingRequests.length === 0
    && snapshot.unreadHandovers.length === 0
    && snapshot.openShoppingItems.length === 0
    && snapshot.briefSchedule.length === 0
    && (snapshot.partnerSummary.critical_items?.length ?? 0) === 0
    && snapshot.reconciliation.remaining_count === 0
    && snapshot.tomorrowImpact.impact_count === 0;
}

function unique(values: Array<string | undefined>) {
  return [...new Set(values.filter((value): value is string => Boolean(value)))];
}

function orderedRows<T extends { id: string }>(ids: string[], rows: T[]) {
  const byId = new Map(rows.map((row) => [row.id, row]));
  return ids.map((id) => byId.get(id)).filter((row): row is T => Boolean(row));
}

export function useTodayData(householdId: string | null, userId: string | null): TodayData {
  const [snapshot, setSnapshot] = useState<TodaySnapshot>(() => emptySnapshot());
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
        setStatus('loading');
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
        p_local_date: tokyoLocalDate(new Date()),
      });
      if (briefError) throw briefError;
      const brief = (briefData ?? {}) as DailyBriefPayload;

      const taskIds = unique((brief.tasks ?? []).map((item) => item.task_id));
      const waitingRefs = brief.waiting_checks ?? [];
      const waitingIds = unique(waitingRefs.map((item) => item.task_id));
      const carryoverRefs = brief.carryovers ?? brief.carryover ?? [];
      const carryoverIds = unique(carryoverRefs.map((item) => item.task_id));
      const handledIds = unique((brief.already_handled ?? []).map((item) => item.task_id));
      const groupRefs = brief.own_task_groups ?? {};
      const groupedIds = unique([
        ...(groupRefs.morning ?? []).map((item) => item.task_id),
        ...(groupRefs.daytime ?? []).map((item) => item.task_id),
        ...(groupRefs.evening ?? []).map((item) => item.task_id),
        ...(groupRefs.optional ?? []).map((item) => item.task_id),
      ]);
      const allTaskIds = unique([...taskIds, ...waitingIds, ...carryoverIds, ...handledIds, ...groupedIds]);

      const urgentActions = brief.urgent_actions ?? [];
      const requestActions = urgentActions.filter((item) => Boolean(item.request_id && item.attempt_id));
      const requestIds = unique(requestActions.map((item) => item.request_id));
      const handoverRefs = brief.active_infos ?? brief.handovers ?? [];
      const handoverIds = unique(handoverRefs.map((item) => item.handover_id));
      const shoppingIds = unique((brief.shopping ?? []).map((item) => item.shopping_item_id));

      const [taskRes, requestRes, handoverRes, shoppingRes] = await Promise.all([
        allTaskIds.length
          ? supabase.from('task_instances').select('*').in('id', allTaskIds)
          : Promise.resolve({ data: [] as TodayTaskInstance[], error: null }),
        requestIds.length
          ? supabase.from('requests').select('*').in('id', requestIds)
          : Promise.resolve({ data: [] as RequestRow[], error: null }),
        handoverIds.length
          ? supabase.from('handovers').select('*').in('id', handoverIds)
          : Promise.resolve({ data: [] as Handover[], error: null }),
        shoppingIds.length
          ? supabase.from('shopping_items').select('*').in('id', shoppingIds)
          : Promise.resolve({ data: [] as ShoppingItem[], error: null }),
      ]);

      for (const result of [taskRes, requestRes, handoverRes, shoppingRes]) {
        if (result.error) throw result.error;
      }

      const taskRows = (taskRes.data ?? []) as TodayTaskInstance[];
      const taskById = new Map(taskRows.map((task) => [task.id, task]));
      const visibleTasks = allTaskIds.map((id) => taskById.get(id)).filter((task): task is TodayTaskInstance => Boolean(task));
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
      const groupHydrate = (refs?: DailyBriefTaskRef[]) => hydrate(unique((refs ?? []).map((item) => item.task_id)));

      const attemptMap = new Map<string, TodayRequestAttempt>();
      for (const item of requestActions) {
        if (!item.request_id || !item.attempt_id || !item.state) continue;
        attemptMap.set(item.request_id, {
          id: item.attempt_id,
          request_id: item.request_id,
          state: item.state,
          revision: item.revision ?? 0,
          terms_revision: item.terms_revision ?? 0,
          reply_due_at: item.reply_due_at ?? null,
        });
      }

      const requestRows = (requestRes.data ?? []) as RequestRow[];
      const nextSnapshot: TodaySnapshot = {
        urgentActions,
        exceptions: brief.exceptions ?? [],
        tasks: hydrate(taskIds),
        taskGroups: {
          morning: groupHydrate(groupRefs.morning),
          daytime: groupHydrate(groupRefs.daytime),
          evening: groupHydrate(groupRefs.evening),
          optional: groupHydrate(groupRefs.optional),
        },
        waitingTasks: hydrate(waitingIds),
        waitingRefsByTaskId: new Map(waitingRefs.map((item) => [item.task_id, item])),
        carryoverTasks: hydrate(carryoverIds),
        alreadyHandledTasks: hydrate(handledIds),
        subtasksByTaskId: groupedSubtasks,
        executionTargetsByTaskId: targetMap,
        incomingRequests: orderedRows(requestIds, requestRows),
        requestAttemptsByRequestId: attemptMap,
        unreadHandovers: orderedRows(handoverIds, (handoverRes.data ?? []) as Handover[]),
        openShoppingItems: orderedRows(shoppingIds, (shoppingRes.data ?? []) as ShoppingItem[]),
        briefSchedule: brief.schedule ?? [],
        partnerSummary: brief.partner_summary ?? {},
        reconciliation: brief.reconciliation ?? EMPTY_RECONCILIATION,
        tomorrowImpact: brief.tomorrow_impact ?? EMPTY_TOMORROW,
        morningSummary: {
          completedCount: brief.morning_summary?.completed_count ?? 0,
          totalCount: brief.morning_summary?.total_count ?? 0,
        },
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
    setSnapshot(emptySnapshot());
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
