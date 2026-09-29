import { useState } from 'react';
import { FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { useCommandAttempt } from '../../lib/useCommandAttempt';
import type { Handover } from '../../lib/types';

/**
 * The two things a person can do with a shared note (Requirements §8.2/§8.3):
 * mark it 確認した (gone from your own Today), or end it for the whole family
 * (「クリアするまで」 notes need someone to clear them; any adult may, owner
 * decision 2026-09-30). Live: the Today card had no button at all, and a note
 * from 08-24 stayed "未読" for five weeks.
 */
export function HandoverActions({
  handover,
  currentUserId,
  isRead,
  onChanged,
}: {
  handover: Pick<Handover, 'id' | 'author_id' | 'ack_policy'>;
  currentUserId: string | null | undefined;
  isRead: boolean;
  onChanged: () => void;
}) {
  const runCommand = useCommandAttempt();
  const [busy, setBusy] = useState(false);
  const [confirmingEnd, setConfirmingEnd] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const isAuthor = Boolean(currentUserId) && handover.author_id === currentUserId;

  async function run(kind: 'read' | 'end') {
    setBusy(true);
    setError(null);
    try {
      await runCommand(
        `handover:${handover.id}:${kind}`,
        kind === 'read' ? EDGE_FUNCTIONS.markHandoverRead : EDGE_FUNCTIONS.endHandover,
        (operationId) => ({ operation_id: operationId, handover_id: handover.id }),
      );
      setConfirmingEnd(false);
      onChanged();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="handover-actions">
      {isAuthor && <span className="task-item-meta">あなたが共有中</span>}
      {!isAuthor && !isRead && (
        <button type="button" disabled={busy} onClick={() => void run('read')}>
          確認した
        </button>
      )}
      {confirmingEnd ? (
        <>
          <span className="task-item-meta">終えると家族全員のTodayから消えます（履歴には残ります）。</span>
          <button type="button" disabled={busy} onClick={() => void run('end')}>終える</button>
          <button type="button" className="secondary-button" disabled={busy} onClick={() => setConfirmingEnd(false)}>やめる</button>
        </>
      ) : (
        <button type="button" className="secondary-button" disabled={busy} onClick={() => setConfirmingEnd(true)}>
          この共有を終える
        </button>
      )}
      {error && <p role="alert" className="error-text">{error}</p>}
    </div>
  );
}
