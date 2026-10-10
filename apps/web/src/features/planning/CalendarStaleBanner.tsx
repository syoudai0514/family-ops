import { useEffect, useState } from 'react';
import type { useCalendarFreshness } from './useCalendarFreshness';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';

type Freshness = ReturnType<typeof useCalendarFreshness>;

// The old banner read "Googleカレンダーの同期が古いか、再接続が必要です。" with no
// control. Following that instruction led to Settings, which reports health
// from connection-level flags (`active` / `reauth_required`) and therefore
// answered "Google Calendar ✓ 接続済み" -- a dead end where the app
// contradicted itself and offered no way forward.
//
// Staleness and lost authorization are different faults with different
// remedies, so this states the fault the user can actually see (events are not
// arriving) and offers the matching action. Reconnection is mentioned only as
// the fallback, after a re-sync has been tried and the data still has not
// arrived.
export function CalendarStaleBanner({
  freshness,
  onSynced,
}: {
  freshness: Freshness;
  onSynced: () => void;
}) {
  const { syncing, error, requestedAt, resync } = freshness;
  const { household } = useHousehold();
  const [reauthNeeded, setReauthNeeded] = useState(false);
  const [connecting, setConnecting] = useState(false);
  const [connectError, setConnectError] = useState<string | null>(null);

  // When Google has withdrawn the permission (owner report 2026-10-10: invalid_grant 7 days after
  // the last connect), re-syncing cannot help. Say so and offer the reconnect itself.
  useEffect(() => {
    if (!household?.id) return;
    let cancelled = false;
    void supabase
      .from('calendar_connections')
      .select('active,reauth_required')
      .eq('household_id', household.id)
      .eq('provider', 'google')
      .then(({ data }) => {
        if (!cancelled) setReauthNeeded((data ?? []).some((row) => row.active && row.reauth_required));
      });
    return () => { cancelled = true; };
  }, [household?.id]);

  async function run() {
    if (await resync()) onSynced();
  }

  async function reconnect() {
    setConnecting(true);
    setConnectError(null);
    try {
      const result = await callEdgeFunction<{ authorization_url: string }>(EDGE_FUNCTIONS.googleCalendarOauthStart, { return_to: '/week' });
      window.location.assign(result.authorization_url);
    } catch (err) {
      setConnectError(err instanceof Error ? err.message : 'Googleカレンダーを開けませんでした。');
      setConnecting(false);
    }
  }

  if (reauthNeeded) {
    return (
      <div className="warning-banner calendar-stale-banner" role="status">
        <div>
          <strong>Googleカレンダーとの接続が切れています</strong>
          <p>Googleの許可が切れたため、予定を読み込めません。再接続すると、また届くようになります。</p>
        </div>
        <div className="calendar-stale-actions">
          <button type="button" onClick={() => void reconnect()} disabled={connecting}>
            {connecting ? '開いています…' : 'Googleカレンダーを再接続'}
          </button>
        </div>
        {connectError && <p className="error-text">{connectError}</p>}
      </div>
    );
  }

  return (
    <div className="warning-banner calendar-stale-banner" role="status">
      <div>
        <strong>Googleカレンダーの予定がまだ届いていません</strong>
        <p>
          {requestedAt
            ? '同期を開始しました。反映まで少し時間がかかることがあります。'
            : '家族カレンダーの読み込みが遅れています。'}
        </p>
      </div>
      <div className="calendar-stale-actions">
        <button type="button" onClick={() => void run()} disabled={syncing}>
          {syncing ? '同期中…' : requestedAt ? 'もう一度同期する' : '今すぐ同期する'}
        </button>
        {requestedAt && (
          <a className="text-button" href="/settings">
            それでも届かないときは接続を確認
          </a>
        )}
      </div>
      {error && <p className="error-text">{error}</p>}
    </div>
  );
}
