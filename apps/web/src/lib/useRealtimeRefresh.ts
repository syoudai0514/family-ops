import { useEffect, useRef } from 'react';
import { supabase } from './supabaseClient';

// WP4 — partner realtime sync. Subscribes to Supabase Realtime
// (`postgres_changes`) on a small set of household-scoped tables and calls
// `onRemoteChange` whenever a row changes, so views like Today and Handovers
// pick up the other member's mutations without a full page reload.
//
// Every row on the tables we watch carries `household_id`, so we can filter
// server-side with `household_id=eq.<id>` and never receive rows outside the
// current household (RLS would block them anyway, but the filter also keeps
// the payload volume down).
//
// Best-effort own-mutation skip: when a changed row exposes a recognizable
// actor/author column, and it matches the current user, we skip the refetch
// — the local edge-function call that caused the mutation already triggered
// its own `refresh()`. Tables without such a column (e.g. `task_instances`,
// which records participants but not "who just touched this row") always
// trigger a refetch; that refetch is cheap and correctness (staying in sync
// with the partner) matters more than saving one redundant round trip.
const ACTOR_COLUMNS_BY_TABLE: Record<string, string[]> = {
  task_events: ['actor_id'],
  handovers: ['author_id'],
  handover_reads: ['user_id'],
};

export const DEFAULT_REALTIME_TABLES = [
  'task_instances',
  'task_events',
  'requests',
  'shopping_items',
  'handovers',
  'handover_reads',
];

interface RealtimeRow {
  [key: string]: unknown;
}

interface RealtimeChangePayload {
  table: string;
  new: RealtimeRow | null;
  old: RealtimeRow | null;
}

function isOwnMutation(payload: RealtimeChangePayload, userId: string | null): boolean {
  if (!userId) return false;
  const columns = ACTOR_COLUMNS_BY_TABLE[payload.table];
  if (!columns) return false;
  const row = payload.new ?? payload.old;
  if (!row) return false;
  return columns.some((col) => row[col] === userId);
}

export interface UseRealtimeRefreshOptions {
  /** Household to scope the subscription to. No subscription is created while null. */
  householdId: string | null;
  /** Current signed-in user, used for the own-mutation skip described above. */
  userId: string | null;
  /** Called (with no args) whenever a relevant remote change is observed. */
  onRemoteChange: () => void;
  /** Tables to watch. Defaults to the set WP4 cares about (see DEFAULT_REALTIME_TABLES). */
  tables?: string[];
  /** Set false to skip subscribing (e.g. while a screen is hidden). Defaults to true. */
  enabled?: boolean;
}

/**
 * Subscribes to Supabase Realtime `postgres_changes` for the given household
 * across `tables`, invoking `onRemoteChange` on every relevant change. Tears
 * the channel down on unmount or when `householdId` changes.
 */
export function useRealtimeRefresh({
  householdId,
  userId,
  onRemoteChange,
  tables = DEFAULT_REALTIME_TABLES,
  enabled = true,
}: UseRealtimeRefreshOptions): void {
  // Keep the latest callback/userId in refs so the subscription effect only
  // needs to depend on `householdId`/`enabled` — re-subscribing on every
  // render (e.g. because the caller passed an inline arrow function) would
  // defeat the point of a live subscription. Updated from an effect (not
  // during render) so we never read/write a ref while rendering.
  const onRemoteChangeRef = useRef(onRemoteChange);
  useEffect(() => {
    onRemoteChangeRef.current = onRemoteChange;
  }, [onRemoteChange]);
  const userIdRef = useRef(userId);
  useEffect(() => {
    userIdRef.current = userId;
  }, [userId]);

  useEffect(() => {
    if (!householdId || !enabled) return;

    const channel = supabase.channel(`household-${householdId}-realtime`);
    for (const table of tables) {
      channel.on(
        'postgres_changes',
        { event: '*', schema: 'public', table, filter: `household_id=eq.${householdId}` },
        (payload: unknown) => {
          const typed = payload as RealtimeChangePayload;
          if (isOwnMutation(typed, userIdRef.current)) return;
          onRemoteChangeRef.current();
        },
      );
    }
    channel.subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
    // `tables` is expected to be a stable reference (the module-level default,
    // or a caller-memoized array) — see the doc comment above.
  }, [householdId, enabled, tables]);
}
