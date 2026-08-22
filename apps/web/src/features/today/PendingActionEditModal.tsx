import { useState, type FormEvent } from 'react';
import { Modal } from '../../components/Modal';
import { useHousehold } from '../../app/HouseholdContext';
import type { PendingAction } from '../../lib/types';

type EditableType = 'task_create_once' | 'request_create' | 'shopping_item_add';

function editableType(action: PendingAction): EditableType | null {
  return action.action_type === 'task_create_once' ||
    action.action_type === 'request_create' ||
    action.action_type === 'shopping_item_add'
    ? action.action_type
    : null;
}

function stringValue(payload: Record<string, unknown>, key: string): string {
  return typeof payload[key] === 'string' ? payload[key] : '';
}

function shortMemberName(name: string | null | undefined): string {
  return name?.trim() || '家族';
}

export function PendingActionEditModal({
  action,
  onSave,
  onClose,
}: {
  action: PendingAction;
  onSave: (actionType: EditableType, payload: Record<string, unknown>) => Promise<void>;
  onClose: () => void;
}) {
  const { members, me } = useHousehold();
  const originalType = editableType(action);
  const initial = action.normalized_payload;
  const [actionType, setActionType] = useState<EditableType>(originalType ?? 'task_create_once');
  const [title, setTitle] = useState(stringValue(initial, 'title'));
  const [scheduledDate, setScheduledDate] = useState(stringValue(initial, 'scheduled_date'));
  const [dueLocalTime, setDueLocalTime] = useState(stringValue(initial, 'due_local_time'));
  const [assigneeId, setAssigneeId] = useState(
    stringValue(initial, 'planned_assignee_user_id') ||
      stringValue(initial, 'assignee_user_id') ||
      me?.user_id ||
      '',
  );
  const [recipientId, setRecipientId] = useState(stringValue(initial, 'recipient_user_id'));
  const [message, setMessage] = useState(stringValue(initial, 'shared_message'));
  const [calendarVisibility, setCalendarVisibility] = useState<'hidden' | 'special'>(
    initial.calendar_visibility === 'special' ? 'special' : 'hidden',
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!originalType) return null;

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!title.trim() || !scheduledDate) {
      setError('タイトルと日付を入力してください。');
      return;
    }
    if (
      actionType === 'request_create' &&
      (!recipientId || recipientId === me?.user_id || !message.trim())
    ) {
      setError('お願いする相手と文面を入力してください。');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const payload: Record<string, unknown> = {
        // Preserve the server-provided private context/checklist.  The Edge
        // Function whitelists and validates every field before it reaches the
        // sender-owned draft row.
        ...initial,
        title: title.trim(),
        scheduled_date: scheduledDate,
        due_local_time: dueLocalTime || null,
      };
      if (actionType === 'task_create_once') {
        payload.planned_assignee_user_id = assigneeId || me?.user_id || null;
        payload.calendar_visibility = calendarVisibility;
        payload.target_label = shortMemberName(
          members.find((m) => m.user_id === payload.planned_assignee_user_id)?.profile
            ?.display_name,
        );
        delete payload.recipient_user_id;
        delete payload.shared_message;
      } else if (actionType === 'request_create') {
        payload.recipient_user_id = recipientId;
        payload.shared_message = message.trim();
        payload.target_label = shortMemberName(
          members.find((m) => m.user_id === recipientId)?.profile?.display_name,
        );
        delete payload.planned_assignee_user_id;
      } else {
        payload.assignee_user_id = assigneeId || null;
        payload.target_label = assigneeId
          ? shortMemberName(members.find((m) => m.user_id === assigneeId)?.profile?.display_name)
          : '買い物リスト';
        delete payload.planned_assignee_user_id;
        delete payload.recipient_user_id;
        delete payload.shared_message;
      }
      await onSave(actionType, payload);
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : '修正を保存できませんでした。');
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal title="確認前の内容を編集" onClose={onClose}>
      <form onSubmit={submit} className="stack-form">
        <p className="empty-hint">
          保存後にもう一度内容を確認します。確定するまで登録・相手への送信は行いません。
        </p>
        <label>
          種別
          <select
            value={actionType}
            onChange={(event) => setActionType(event.target.value as EditableType)}
            disabled={busy}
          >
            <option value="task_create_once">タスク</option>
            <option value="request_create">お願い</option>
            <option value="shopping_item_add">買い物</option>
          </select>
        </label>
        <label>
          タイトル
          <input
            value={title}
            onChange={(event) => setTitle(event.target.value)}
            required
            disabled={busy}
          />
        </label>
        <label>
          日付
          <input
            type="date"
            value={scheduledDate}
            onChange={(event) => setScheduledDate(event.target.value)}
            required
            disabled={busy}
          />
        </label>
        <label>
          時刻（任意）
          <input
            type="time"
            value={dueLocalTime}
            onChange={(event) => setDueLocalTime(event.target.value)}
            disabled={busy}
          />
        </label>
        {actionType === 'task_create_once' && (
          <>
            <label>
              担当
              <select
                value={assigneeId}
                onChange={(event) => setAssigneeId(event.target.value)}
                disabled={busy}
              >
                {members.map((member) => (
                  <option key={member.user_id} value={member.user_id}>
                    {shortMemberName(member.profile?.display_name)}
                  </option>
                ))}
              </select>
            </label>
            <label>
              予定への表示
              <select
                value={calendarVisibility}
                onChange={(event) =>
                  setCalendarVisibility(event.target.value as 'hidden' | 'special')
                }
                disabled={busy}
              >
                <option value="special">特別対応として月・週・Google Calendarに表示</option>
                <option value="hidden">タスクのみ（Google Calendarへ同期しない）</option>
              </select>
            </label>
          </>
        )}
        {actionType === 'request_create' && (
          <>
            <label>
              お願いする相手
              <select
                value={recipientId}
                onChange={(event) => setRecipientId(event.target.value)}
                disabled={busy}
              >
                <option value="">選んでください</option>
                {members
                  .filter((member) => member.user_id !== me?.user_id)
                  .map((member) => (
                    <option key={member.user_id} value={member.user_id}>
                      {shortMemberName(member.profile?.display_name)}
                    </option>
                  ))}
              </select>
            </label>
            <label>
              相手へ送る文面
              <textarea
                value={message}
                onChange={(event) => setMessage(event.target.value)}
                disabled={busy}
              />
            </label>
          </>
        )}
        {actionType === 'shopping_item_add' && (
          <label>
            担当（任意）
            <select
              value={assigneeId}
              onChange={(event) => setAssigneeId(event.target.value)}
              disabled={busy}
            >
              <option value="">未定</option>
              {members.map((member) => (
                <option key={member.user_id} value={member.user_id}>
                  {shortMemberName(member.profile?.display_name)}
                </option>
              ))}
            </select>
          </label>
        )}
        {error && (
          <p role="alert" className="error-text">
            {error}
          </p>
        )}
        <div className="modal-actions">
          <button type="submit" disabled={busy}>
            {busy ? '保存中…' : '修正して確認へ'}
          </button>
          <button type="button" onClick={onClose} disabled={busy}>
            戻る
          </button>
        </div>
      </form>
    </Modal>
  );
}
