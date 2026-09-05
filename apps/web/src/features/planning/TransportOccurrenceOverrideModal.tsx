import { useEffect, useState } from 'react';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import { Modal } from '../../components/Modal';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';

type OverrideRow = {
  id: string;
  occurrence_date: string;
  dropoff_overridden: boolean;
  dropoff_user_id: string | null;
  pickup_overridden: boolean;
  pickup_user_id: string | null;
  note: string | null;
};

type ReadResult = { overrides?: OverrideRow[] };

export function TransportOccurrenceOverrideModal({
  date,
  members,
  baseDropoffUserId,
  basePickupUserId,
  onClose,
  onChanged,
}: {
  date: string;
  members: HouseholdMemberWithProfile[];
  baseDropoffUserId: string | null;
  basePickupUserId: string | null;
  onClose: () => void;
  onChanged: () => void | Promise<void>;
}) {
  const [dropoffOverridden, setDropoffOverridden] = useState(false);
  const [pickupOverridden, setPickupOverridden] = useState(false);
  const [dropoffUserId, setDropoffUserId] = useState(baseDropoffUserId ?? '');
  const [pickupUserId, setPickupUserId] = useState(basePickupUserId ?? '');
  const [note, setNote] = useState('');
  const [existing, setExisting] = useState(false);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const result = await callEdgeFunction<ReadResult>(EDGE_FUNCTIONS.transportSchedule, { action: 'read' });
        if (cancelled) return;
        const row = result.overrides?.find((item) => item.occurrence_date === date);
        if (row) {
          setExisting(true);
          setDropoffOverridden(row.dropoff_overridden);
          setPickupOverridden(row.pickup_overridden);
          setDropoffUserId(row.dropoff_overridden ? row.dropoff_user_id ?? '' : baseDropoffUserId ?? '');
          setPickupUserId(row.pickup_overridden ? row.pickup_user_id ?? '' : basePickupUserId ?? '');
          setNote(row.note ?? '');
        }
      } catch (err) {
        if (!cancelled) setError(err instanceof FamilyOpsApiError ? err.message : 'この日の変更を読み込めませんでした。');
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [baseDropoffUserId, basePickupUserId, date]);

  async function save() {
    if (!dropoffOverridden && !pickupOverridden) {
      setError('変更する「送り」または「お迎え」を選んでください。');
      return;
    }
    setSaving(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.transportSchedule, {
        action: 'set_override',
        operation_id: newOperationId(),
        occurrence_date: date,
        dropoff_overridden: dropoffOverridden,
        dropoff_user_id: dropoffOverridden ? dropoffUserId || null : null,
        pickup_overridden: pickupOverridden,
        pickup_user_id: pickupOverridden ? pickupUserId || null : null,
        note: note.trim() || null,
      });
      await onChanged();
      onClose();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : 'この日の送り迎えを変更できませんでした。');
    } finally {
      setSaving(false);
    }
  }

  async function restoreBase() {
    if (!existing) {
      onClose();
      return;
    }
    setSaving(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.transportSchedule, {
        action: 'delete_override',
        operation_id: newOperationId(),
        occurrence_date: date,
      });
      await onChanged();
      onClose();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '基本の生活パターンへ戻せませんでした。');
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal title="この日だけ送り迎えを変更" onClose={onClose}>
      {loading ? (
        <p role="status">読み込み中…</p>
      ) : (
        <div className="form-stack">
          <p className="empty-hint">{date}だけの変更です。いつもの生活パターンや他の日には影響しません。</p>
          <label>
            <input
              type="checkbox"
              checked={dropoffOverridden}
              onChange={(event) => setDropoffOverridden(event.target.checked)}
            />
            送りだけ変更する
          </label>
          {dropoffOverridden && (
            <label>
              送り担当
              <select value={dropoffUserId} onChange={(event) => setDropoffUserId(event.target.value)}>
                <option value="">なし</option>
                {members.map((member) => (
                  <option key={member.user_id} value={member.user_id}>{member.profile?.display_name ?? '家族'}</option>
                ))}
              </select>
            </label>
          )}
          <label>
            <input
              type="checkbox"
              checked={pickupOverridden}
              onChange={(event) => setPickupOverridden(event.target.checked)}
            />
            お迎えだけ変更する
          </label>
          {pickupOverridden && (
            <label>
              お迎え担当
              <select value={pickupUserId} onChange={(event) => setPickupUserId(event.target.value)}>
                <option value="">なし</option>
                {members.map((member) => (
                  <option key={member.user_id} value={member.user_id}>{member.profile?.display_name ?? '家族'}</option>
                ))}
              </select>
            </label>
          )}
          <label>
            メモ（任意）
            <input value={note} maxLength={500} onChange={(event) => setNote(event.target.value)} />
          </label>
          {error && <p role="alert" className="error-text">{error}</p>}
          <button type="button" onClick={save} disabled={saving}>この日だけ変更</button>
          <button type="button" className="secondary-button" onClick={restoreBase} disabled={saving}>
            {existing ? 'この日の変更を削除して基本に戻す' : '変更せず戻る'}
          </button>
        </div>
      )}
    </Modal>
  );
}
