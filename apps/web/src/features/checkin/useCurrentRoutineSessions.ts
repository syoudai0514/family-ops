import { useCallback, useEffect, useState } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';

export type CurrentRoutineSessionType = 'dropoff' | 'pickup' | 'nonpickup_evening';

export interface CurrentRoutineSession {
  id: string;
  session_type: CurrentRoutineSessionType;
  scheduled_date: string;
  status: 'open';
  assignee_id: string;
  can_act: boolean;
  remaining_count: number;
}

export function useCurrentRoutineSessions(enabled: boolean) {
  const [sessions, setSessions] = useState<CurrentRoutineSession[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    if (!enabled) {
      setSessions([]);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const result = await callEdgeFunction<{ sessions?: CurrentRoutineSession[] }>(
        EDGE_FUNCTIONS.getCurrentRoutineSessions,
        {},
      );
      setSessions(result.sessions ?? []);
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '入力の確認に失敗しました。');
    } finally {
      setLoading(false);
    }
  }, [enabled]);

  useEffect(() => { void refresh(); }, [refresh]);
  return { sessions, loading, error, refresh };
}
