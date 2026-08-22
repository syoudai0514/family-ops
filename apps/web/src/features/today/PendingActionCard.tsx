import { useState } from 'react';
import { FamilyOpsApiError } from '../../lib/apiClient';
import type { PendingAction } from '../../lib/types';

// Sol re-review #3 fix (P1-1, docs/adr/0011): Today Priority 2's "LINEから
// 作ったpending action" card. Three action_type shapes, each previewed
// safely (this is always the SENDER's own draft, per usePendingActions'
// actor-scoped RPC — never the partner's, so raw text here is never
// exposed to anyone else):
//   - shopping_item_add / task_create_once: already-structured (parser.ts
//     produced them deterministically) — preview the parsed fields
//     directly, confirm executes them via the existing worker
//     (process-pending-actions already handles both action_types).
//   - needs_pwa_review: the parser found no deterministic match. The
//     execution worker has NO case for this action_type (see
//     process-pending-actions/index.ts's `default: throw`), so confirming
//     it would only dead-letter — no confirm button is offered at all;
//     only cancel and a correction path into the normal task form
//     (request or task correction), matching "Parser fallback leads to a
//     usable correction/form path rather than a dead end."
interface PendingActionCardProps {
  action: PendingAction;
  onConfirm: (id: string) => Promise<void>;
  onCancel: (id: string) => Promise<void>;
  onEdit: (action: PendingAction) => void;
  onEditAsRequest: (action: PendingAction) => Promise<void>;
  onEditAsTask: (action: PendingAction) => Promise<void>;
}

const ACTION_TITLES: Record<PendingAction['action_type'], string> = {
  shopping_item_add: '🛒 買い物リストに追加',
  task_create_once: '📝 タスクを追加',
  request_create: '💬 お願いを送る',
  assignment_change_request: '🚗 お迎え担当のお願い',
  needs_pwa_review: '✏️ LINEからの入力（内容の確認が必要）',
};

function previewText(action: PendingAction): string {
  const p = action.normalized_payload;
  switch (action.action_type) {
    case 'shopping_item_add':
      return String(p.title ?? '');
    case 'task_create_once':
      return `${String(p.title ?? '')}（${String(p.scheduled_date ?? '')}）`;
    case 'assignment_change_request':
      return `${String(p.shared_message ?? '')}（${String(p.scheduled_date ?? '')}）`;
    case 'request_create':
      return `${String(p.title ?? '')}（${String(p.scheduled_date ?? '')}）`;
    case 'needs_pwa_review':
      return String(p.raw_text ?? '');
    default:
      return '';
  }
}

export function PendingActionCard({
  action,
  onConfirm,
  onCancel,
  onEdit,
  onEditAsRequest,
  onEditAsTask,
}: PendingActionCardProps) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run(fn: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。');
    } finally {
      setBusy(false);
    }
  }

  const isProcessing = action.status !== 'draft';

  return (
    <li className="pending-action-item">
      <div>
        <strong>{ACTION_TITLES[action.action_type] ?? action.action_type}</strong>
        <p>{previewText(action)}</p>
        {isProcessing && <span className="task-item-meta">処理中…</span>}
      </div>
      {!isProcessing && (
        <div className="task-item-actions">
          {action.action_type === 'needs_pwa_review' ? (
            <>
              <button
                type="button"
                disabled={busy}
                onClick={() => run(() => onEditAsRequest(action))}
              >
                お願いとして編集
              </button>
              <button type="button" disabled={busy} onClick={() => run(() => onEditAsTask(action))}>
                タスクとして編集
              </button>
            </>
          ) : (
            <>
              <button type="button" disabled={busy} onClick={() => onEdit(action)}>
                編集
              </button>
              <button type="button" disabled={busy} onClick={() => run(() => onConfirm(action.id))}>
                この内容で確定
              </button>
            </>
          )}
          <button type="button" disabled={busy} onClick={() => run(() => onCancel(action.id))}>
            キャンセル
          </button>
        </div>
      )}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </li>
  );
}
