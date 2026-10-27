import { useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';

const NUDGE_TIMES = ['07:00', '07:15', '07:30', '07:45', '08:00'];
export const DEFAULT_MORNING_NUDGE = '07:30';

/** 朝の残り: one LINE / push message on workdays listing what is still open this morning. */
export function MorningNudgeSection() {
  const { household, refresh } = useHousehold();
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  if (!household) return null;

  // undefined = column not read yet (older data): show the default rather than "off".
  const stored = household.morning_nudge_local_time;
  const current = stored === undefined ? DEFAULT_MORNING_NUDGE : stored === null ? '' : stored.slice(0, 5);
  const options = current && !NUDGE_TIMES.includes(current) ? [...NUDGE_TIMES, current].sort() : NUDGE_TIMES;

  async function change(value: string) {
    setSaving(true);
    setError(null);
    setSaved(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.updateNotificationPreferences, {
        operation_id: newOperationId(),
        reminder_settings: { morning_nudge_local_time: value || null },
      });
      await refresh();
      setSaved(value ? `平日の${value}に、朝まだ終わっていないことをお知らせします。` : '朝の残りのお知らせをやめました。');
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '保存できませんでした。もう一度お試しください。');
    } finally {
      setSaving(false);
    }
  }

  return (
    <section className="card">
      <h2>朝の残りのお知らせ</h2>
      <p className="form-help">
        平日の朝、まだ終わっていない朝のことを1通だけお知らせします（全部終わっていれば何も送りません）。LINEと、スマホの通知をオンにした端末に届きます。家族で共通の設定です。
      </p>
      <label className="form-field">
        お知らせの時刻
        <select value={current} disabled={saving} onChange={(e) => void change(e.target.value)}>
          <option value="">お知らせしない</option>
          {options.map((time) => (
            <option key={time} value={time}>
              {time}
            </option>
          ))}
        </select>
      </label>
      {saved && <p role="status">{saved}</p>}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </section>
  );
}
