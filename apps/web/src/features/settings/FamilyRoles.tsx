import { useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { useCommandAttempt } from '../../lib/useCommandAttempt';

export function FamilyRoles() {
  const { members, refresh } = useHousehold();
  const run = useCommandAttempt();
  const [change, setChange] = useState<{ userId: string; role: 'papa' | 'mama' } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const target = members.find((member) => member.user_id === change?.userId);
  const other = members.find(
    (member) => member.user_id !== change?.userId && member.family_role === change?.role,
  );
  async function save() {
    if (!change || busy) return;
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      await run(
        `family-role:${change.userId}:${change.role}`,
        EDGE_FUNCTIONS.setFamilyRole,
        (operationId) => ({
          operation_id: operationId,
          user_id: change.userId,
          family_role: change.role,
        }),
      );
      await refresh();
      setChange(null);
      setNotice('家族の表示を保存しました。');
    } catch (err) {
      setError(
        err instanceof FamilyOpsApiError
          ? err.message
          : '保存できませんでした。選んだ内容は残っています。',
      );
    } finally {
      setBusy(false);
    }
  }
  return (
    <section aria-label="家族の表示">
      <p className="empty-hint">
        予定やLINEで使う呼び名と色です。実際にやった人の記録は変更しません。
      </p>
      <div className="family-role-rows">
        {members.map((member) => (
          <label key={member.user_id}>
            {member.profile?.display_name ?? '家族'}
            <select
              disabled={busy}
              value={change?.userId === member.user_id ? change.role : (member.family_role ?? '')}
              onChange={(e) => {
                if (e.target.value) {
                  setChange({ userId: member.user_id, role: e.target.value as 'papa' | 'mama' });
                  setError(null);
                  setNotice(null);
                }
              }}
            >
              <option value="">未設定</option>
              <option value="papa">パパ（緑）</option>
              <option value="mama">ママ（橙）</option>
            </select>
          </label>
        ))}
      </div>
      {change && (
        <div className="card" aria-label="呼び名の変更確認">
          <strong>この表示に変更しますか？</strong>
          <p>
            {target?.profile?.display_name ?? '家族'} →{' '}
            {change.role === 'papa' ? 'パパ（緑）' : 'ママ（橙）'}
          </p>
          {other && (
            <p>
              {other.profile?.display_name ?? 'もう一人'} →{' '}
              {target?.family_role === 'papa' || (!target?.family_role && change.role === 'mama')
                ? 'パパ（緑）'
                : 'ママ（橙）'}
            </p>
          )}
          <div className="button-row">
            <button disabled={busy} onClick={() => void save()}>
              {busy ? '保存中…' : 'この表示で保存'}
            </button>
            <button
              className="text-button"
              disabled={busy}
              onClick={() => {
                setChange(null);
                setError(null);
              }}
            >
              やめる
            </button>
          </div>
        </div>
      )}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      {notice && <p role="status">{notice}</p>}
    </section>
  );
}
