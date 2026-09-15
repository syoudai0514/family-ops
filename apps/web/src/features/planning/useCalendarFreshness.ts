import { useCallback, useEffect, useRef, useState } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';

// `ensure-calendar-fresh` has always existed server-side, and its own header
// comment says it is "called when the PWA opens the calendar view ... so a
// stale cache gets a coalesced sync enqueued". That call site was never
// written, so nothing in the PWA ever asked Google for fresh data: the cache
// went stale and stayed stale, the week view reported `calendar_stale`
// forever, and the settings screen -- which only looks at connection-level
// `active` / `reauth_required` flags -- kept answering "接続済み". This hook is
// that missing call site, and it is also the remedy offered next to the
// warning so both screens act on the same signal.
//
// The server coalesces (p_stale_minutes: 5), so calling on every mount is
// cheap; `auto` exists only so tests can opt out of the mount-time call.
export function useCalendarFreshness({ enabled = true, auto = true }: { enabled?: boolean; auto?: boolean } = {}) {
  const [syncing, setSyncing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [requestedAt, setRequestedAt] = useState<number | null>(null);
  const autoRequested = useRef(false);

  const resync = useCallback(async (): Promise<boolean> => {
    setSyncing(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.ensureCalendarFresh, {});
      setRequestedAt(Date.now());
      return true;
    } catch (err) {
      setError(
        err instanceof FamilyOpsApiError
          ? err.message
          : 'Googleカレンダーの再同期を開始できませんでした。',
      );
      return false;
    } finally {
      setSyncing(false);
    }
  }, []);

  useEffect(() => {
    // Opening the calendar is itself the trigger; a failure here must never
    // block rendering, so the error is surfaced only next to the warning.
    if (!enabled || !auto || autoRequested.current) return;
    autoRequested.current = true;
    void resync();
  }, [auto, enabled, resync]);

  return { syncing, error, requestedAt, resync };
}
