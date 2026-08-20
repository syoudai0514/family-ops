import { useCallback, useEffect, useState } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { useRealtimeRefresh } from '../../lib/useRealtimeRefresh';
import type { TodaySchedule } from '../../lib/types';

// Sol re-review #3 fix (P1-2, docs/adr/0011): Today Priority 1's "今/次の予定"
// (02_UX_AND_SCREENS.md #3). Unlike pending actions, calendar_event_
// occurrences/task_instances ARE public-schema tables Realtime can watch, so
// a genuine live refresh (not polling) is used here — task reassignment or
// a fresh calendar sync both land in these tables.
const SCHEDULE_REALTIME_TABLES = ['task_instances', 'calendar_event_occurrences', 'calendar_occurrence_busy_members'];

export interface UseTodayScheduleResult {
  loading: boolean;
  error: string | null;
  schedule: TodaySchedule | null;
  refresh: () => Promise<void>;
}

export function useTodaySchedule(householdId: string | null, userId: string | null): UseTodayScheduleResult {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [schedule, setSchedule] = useState<TodaySchedule | null>(null);

  const load = useCallback(async () => {
    if (!householdId || !userId) {
      setLoading(false);
      return;
    }
    setError(null);
    try {
      const result = await callEdgeFunction<TodaySchedule>(EDGE_FUNCTIONS.getTodaySchedule, {});
      setSchedule(result);
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '予定の読み込みに失敗しました。');
    } finally {
      setLoading(false);
    }
  }, [householdId, userId]);

  useEffect(() => {
    load();
  }, [load]);

  useRealtimeRefresh({ householdId, userId, onRemoteChange: load, tables: SCHEDULE_REALTIME_TABLES });

  return { loading, error, schedule, refresh: load };
}
