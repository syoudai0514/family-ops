import { useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { useCommandAttempt } from '../../lib/useCommandAttempt';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';

export function StartToday() {
  const { refresh } = useHousehold();
  const run = useCommandAttempt();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function start() {
    setBusy(true);
    setError(null);
    try {
      await run('onboarding:finish-later', EDGE_FUNCTIONS.familySetup, (operation_id) => ({
        operation_id,
        action: 'finish_later',
      }));
      await refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : '開始できませんでした。');
    } finally {
      setBusy(false);
    }
  }
  return (
    <section className="card start-today">
      <h2>まず今日から使う</h2>
      <p>
        最初の用事を追加して始められます。いつもの担当・通知・連携は、あとで設定から整えられます。
      </p>
      <button disabled={busy} onClick={() => void start()}>
        {busy ? '準備中…' : '細かい設定は後で、使い始める'}
      </button>
      {error && <p role="alert">{error}</p>}
    </section>
  );
}
