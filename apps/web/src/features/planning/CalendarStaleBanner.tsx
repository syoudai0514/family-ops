import type { useCalendarFreshness } from './useCalendarFreshness';

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

  async function run() {
    if (await resync()) onSynced();
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
