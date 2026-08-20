import { useCallback, useEffect, useRef, useState } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import type { PendingAction } from '../../lib/types';

// Sol re-review #3 fix (P1-1, docs/adr/0011): Today Priority 2's "LINEから
// 作ったpending action" (02_UX_AND_SCREENS.md #3). private.pending_actions
// is not in PostgREST's exposed schema list (only `public`/`graphql_public`
// — see supabase/config.toml), so unlike useTodayData's task/request/etc.
// reads this cannot use Supabase Realtime's postgres_changes at all; a LINE-
// created draft has no channel to push through. Polling is the pragmatic
// substitute for "Realtime or refresh behavior after LINE-created pending
// action" (acceptance criterion): cheap (one Edge Function call), and the
// user's own confirm/cancel already triggers an immediate refetch on top of
// this, so the poll interval only matters for the LINE-origin case.
const POLL_INTERVAL_MS = 20_000;

export interface UsePendingActionsResult {
  loading: boolean;
  error: string | null;
  pendingActions: PendingAction[];
  confirm: (id: string) => Promise<void>;
  cancel: (id: string) => Promise<void>;
  refresh: () => Promise<void>;
}

export function usePendingActions(householdId: string | null, userId: string | null): UsePendingActionsResult {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [pendingActions, setPendingActions] = useState<PendingAction[]>([]);

  const load = useCallback(async () => {
    if (!householdId || !userId) {
      setLoading(false);
      return;
    }
    setError(null);
    try {
      const result = await callEdgeFunction<PendingAction[]>(EDGE_FUNCTIONS.listPendingActions, {});
      setPendingActions(result);
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '判断待ちの読み込みに失敗しました。');
    } finally {
      setLoading(false);
    }
  }, [householdId, userId]);

  useEffect(() => {
    load();
  }, [load]);

  const loadRef = useRef(load);
  useEffect(() => {
    loadRef.current = load;
  }, [load]);

  useEffect(() => {
    if (!householdId || !userId) return;
    const interval = setInterval(() => {
      loadRef.current();
    }, POLL_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [householdId, userId]);

  const confirm = useCallback(
    async (id: string) => {
      await callEdgeFunction(EDGE_FUNCTIONS.confirmPendingAction, { pending_action_id: id });
      await load();
    },
    [load],
  );

  const cancel = useCallback(
    async (id: string) => {
      await callEdgeFunction(EDGE_FUNCTIONS.cancelPendingAction, { pending_action_id: id });
      await load();
    },
    [load],
  );

  return { loading, error, pendingActions, confirm, cancel, refresh: load };
}
