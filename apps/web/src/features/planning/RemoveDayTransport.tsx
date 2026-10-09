import { useState } from 'react';
import { FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { useCommandAttempt } from '../../lib/useCommandAttempt';
import { dayHasTransportToClear } from './dayTransport';
import type { PlanningTask } from './calendarProjection';

/**
 * "この日は送迎なし": clears the day's dropoff / pickup together with their people (owner
 * 2026-10-09: 祝日など). Two steps so a stray tap cannot do it; the tasks are cancelled, not
 * deleted, so the day is never made again.
 */
export function RemoveDayTransport({ date, tasks, onChanged }: { date: string; tasks: PlanningTask[]; onChanged: () => void | Promise<void> }) {
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const runCommand = useCommandAttempt();

  if (!dayHasTransportToClear(tasks, date)) return null;

  async function clearDay() {
    setBusy(true);
    setError(null);
    try {
      await runCommand(`day-transport:clear:${date}`, EDGE_FUNCTIONS.transportSchedule, (operationId) => ({ action: 'clear_day', operation_id: operationId, date }));
      setConfirming(false);
      await onChanged();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '送迎を外せませんでした。もう一度お試しください。');
    } finally {
      setBusy(false);
    }
  }

  if (!confirming) {
    return (
      <div className="day-agenda-clear-transport">
        <button type="button" className="text-button" onClick={() => setConfirming(true)}>
          この日は送迎なし（祝日・休みの日）
        </button>
      </div>
    );
  }
  return (
    <div className="day-agenda-clear-transport confirming" role="alertdialog" aria-label="この日の送迎を外す確認">
      <p>
        この日の送り・迎えと、コドモン、平日だけの朝のタスクを外します。毎日あるもの（薬・夕食など）は「誰でもOK」で残ります。
      </p>
      <div className="day-agenda-clear-transport-actions">
        <button type="button" className="danger-button" onClick={() => void clearDay()} disabled={busy}>
          外す
        </button>
        <button type="button" className="text-button" onClick={() => { setConfirming(false); setError(null); }} disabled={busy}>
          やめる
        </button>
      </div>
      {error && <p role="alert" className="error-text">{error}</p>}
    </div>
  );
}
