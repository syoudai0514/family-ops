import { useCallback, useEffect, useState } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import type { TodaySchedule } from '../../lib/types';
export function useWeekSchedule(householdId: string | null, start: string, end: string) {
  const [schedule, setSchedule] = useState<TodaySchedule | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => {
    if (!householdId) return;
    try {
      setSchedule(
        await callEdgeFunction<TodaySchedule>(EDGE_FUNCTIONS.getWeekSchedule, {
          start_date: start,
          end_date: end,
        }),
      );
      setError(null);
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '競合情報を読み込めませんでした。');
    }
  }, [end, householdId, start]);
  useEffect(() => {
    load();
  }, [load]);
  return { schedule, error, refresh: load };
}
