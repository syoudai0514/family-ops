import { useState, type FormEvent } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import type { TaskInstance, TaskSubtaskInstance } from '../../lib/types';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';

export interface TaskChecklistItemProps {
  task: TaskInstance;
  subtasks: TaskSubtaskInstance[];
  members: HouseholdMemberWithProfile[];
  hasPartner: boolean;
  onEdit: (task: TaskInstance) => void;
  onChanged: () => void;
  showTime?: boolean;
}

function assigneeLabel(task: TaskInstance, members: HouseholdMemberWithProfile[]): string {
  if (!task.planned_assignee_id) return '未定';
  const member = members.find((m) => m.user_id === task.planned_assignee_id);
  if (member?.family_role === 'papa') return 'パパ';
  if (member?.family_role === 'mama') return 'ママ';
  return member?.profile?.display_name ?? '担当あり';
}

function localClock(value: string | null) {
  if (!value) return '';
  return new Intl.DateTimeFormat('ja-JP', {
    timeZone: 'Asia/Tokyo',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(new Date(value));
}

export function TaskChecklistItem({
  task,
  subtasks,
  members,
  hasPartner,
  onEdit,
  onChanged,
  showTime = true,
}: TaskChecklistItemProps) {
  const completed = task.status === 'completed';
  const editable = task.origin === 'manual' && !completed;
  const [expanded, setExpanded] = useState(task.completion_mode === 'subtasks' && !completed);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [actor, setActor] = useState<'self' | 'partner'>('self');
  const [editingWaiting, setEditingWaiting] = useState(false);
  const [waitingNote, setWaitingNote] = useState(task.waiting_note ?? '');
  const [nextCheckAt, setNextCheckAt] = useState(() => toDateTimeLocal(task.next_check_at));
  const doneSubtasks = subtasks.filter((item) => item.is_completed).length;
  const requiredSubtasks = subtasks.filter((item) => item.required);
  const optionalOnlyChecklist =
    task.completion_mode === 'subtasks' && subtasks.length > 0 && requiredSubtasks.length === 0;

  async function withOperation(fn: (operationId: string) => Promise<unknown>): Promise<boolean> {
    setError(null);
    setBusy(true);
    try {
      await fn(newOperationId());
      onChanged();
      return true;
    } catch (err) {
      if (err instanceof FamilyOpsApiError && err.code === 'TASK_TERMINAL') {
        setError('この項目はすでに完了・キャンセル済みです。');
      } else {
        setError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。');
      }
      return false;
    } finally {
      setBusy(false);
    }
  }

  function handleComplete() {
    void withOperation((operationId) =>
      callEdgeFunction(EDGE_FUNCTIONS.completeTask, {
        operation_id: operationId,
        task_id: task.id,
        completion_actor: actor,
        complete_remaining_subtasks: task.completion_mode === 'subtasks',
      }),
    );
  }

  function handleCancel() {
    void withOperation((operationId) =>
      callEdgeFunction(EDGE_FUNCTIONS.cancelTask, {
        operation_id: operationId,
        task_id: task.id,
      }),
    );
  }

  function handleToggleSubtask(subtask: TaskSubtaskInstance) {
    void withOperation((operationId) =>
      callEdgeFunction(EDGE_FUNCTIONS.setSubtaskCompletion, {
        operation_id: operationId,
        subtask_instance_id: subtask.id,
        completed: !subtask.is_completed,
        completion_actor: actor,
      }),
    );
  }

  function handleWaitingSubmit(event: FormEvent) {
    event.preventDefault();
    void withOperation((operationId) => callEdgeFunction(EDGE_FUNCTIONS.setTaskWaiting, {
      operation_id: operationId,
      task_id: task.id,
      waiting_action: task.attention_state === 'waiting' ? 'update' : 'set',
      waiting_note: waitingNote.trim() || null,
      next_check_at: nextCheckAt ? new Date(nextCheckAt).toISOString() : undefined,
      expected_revision: task.revision ?? 1,
    })).then((succeeded) => { if (succeeded) setEditingWaiting(false); });
  }

  function handleResumeWaiting() {
    void withOperation((operationId) => callEdgeFunction(EDGE_FUNCTIONS.setTaskWaiting, {
      operation_id: operationId,
      task_id: task.id,
      waiting_action: 'resume',
      expected_revision: task.revision ?? 1,
    }));
  }

  return (
    <li className={['task-item', 'task-checklist-item', completed ? 'completed' : ''].filter(Boolean).join(' ')}>
      <div className="task-checklist-main">
        {task.completion_mode === 'whole' ? (
          <button
            type="button"
            className="task-check-control"
            aria-label={completed ? `${task.title}は完了済み` : `${task.title}を完了にする`}
            onClick={handleComplete}
            disabled={busy || completed}
          >
            {completed ? '✓' : ''}
          </button>
        ) : (
          <button
            type="button"
            className="task-check-control task-progress-control"
            aria-label={`${task.title}のチェック項目を${expanded ? '閉じる' : '開く'}`}
            onClick={() => setExpanded((value) => !value)}
            disabled={busy}
          >
            {completed ? '✓' : subtasks.length > 0 ? `${doneSubtasks}/${subtasks.length}` : '…'}
          </button>
        )}

        <button
          type="button"
          className="task-checklist-content"
          onClick={() => task.completion_mode === 'subtasks' && setExpanded((value) => !value)}
          disabled={busy && task.completion_mode === 'subtasks'}
        >
          <strong>{task.title}</strong>
          <span className="task-item-meta">
            {showTime && task.due_at ? `${localClock(task.due_at)} · ` : ''}
            {assigneeLabel(task, members)}
            {task.completion_mode === 'subtasks' && subtasks.length > 0
              ? ` · ${doneSubtasks}/${subtasks.length}項目`
              : ''}
            {task.attention_state === 'waiting' ? ` · 待ち${task.next_check_at ? `（確認 ${localClock(task.next_check_at)}）` : ''}` : ''}
          </span>
        </button>

        {optionalOnlyChecklist && !completed && (
          <button
            type="button"
            className="secondary-button task-inline-finish"
            onClick={handleComplete}
            disabled={busy}
          >
            完了
          </button>
        )}

        <details className="task-overflow">
          <summary aria-label="その他の操作">•••</summary>
          <div>
            {hasPartner && (
              <label>
                実施者
                <select
                  aria-label="実施者"
                  value={actor}
                  onChange={(e) => setActor(e.target.value as 'self' | 'partner')}
                  disabled={busy}
                >
                  <option value="self">自分</option>
                  <option value="partner">パートナー</option>
                </select>
              </label>
            )}
            {editable && (
              <button type="button" onClick={() => onEdit(task)} disabled={busy}>
                編集
              </button>
            )}
            {!editable && !completed && task.origin !== 'manual' && (
              <small className="task-menu-note">定例から作られた項目です</small>
            )}
            {!completed && task.attention_state !== 'waiting' && (
              <button type="button" onClick={() => setEditingWaiting(true)} disabled={busy}>待ちにする</button>
            )}
            {!completed && task.attention_state === 'waiting' && (
              <>
                <button type="button" onClick={handleResumeWaiting} disabled={busy}>再開する</button>
                <button type="button" onClick={() => setEditingWaiting(true)} disabled={busy}>確認日を変更</button>
              </>
            )}
            <button
              type="button"
              className="danger-button"
              onClick={handleCancel}
              disabled={busy || completed}
            >
              キャンセル
            </button>
          </div>
        </details>
      </div>

      {expanded && task.completion_mode === 'subtasks' && (
        <ul className="subtask-list subtask-checklist">
          {subtasks.length === 0 ? (
            <li className="empty-hint">チェック項目が設定されていません。</li>
          ) : (
            subtasks.map((subtask) => (
              <li key={subtask.id}>
                <label className="subtask-check-row">
                  <input
                    type="checkbox"
                    checked={subtask.is_completed}
                    disabled={busy || completed}
                    onChange={() => handleToggleSubtask(subtask)}
                  />
                  <span className={subtask.is_completed ? 'checked' : ''}>
                    {subtask.title}
                    {!subtask.required && <small> 任意</small>}
                  </span>
                </label>
              </li>
            ))
          )}
          {optionalOnlyChecklist && !completed && (
            <li className="empty-hint">必要な項目だけチェックして、最後に「完了」を押します。</li>
          )}
        </ul>
      )}

      {editingWaiting && (
        <form className="task-waiting-editor" onSubmit={handleWaitingSubmit}>
          <label>待っている理由（任意）<input value={waitingNote} onChange={(event) => setWaitingNote(event.target.value)} placeholder="例: 園から返事待ち" /></label>
          <label>次に確認する日（任意）<input type="datetime-local" value={nextCheckAt} onChange={(event) => setNextCheckAt(event.target.value)} /></label>
          <div className="task-item-actions"><button type="submit" disabled={busy}>{task.attention_state === 'waiting' ? '待ちを続ける' : '待ちにする'}</button><button type="button" className="text-button" onClick={() => setEditingWaiting(false)} disabled={busy}>やめる</button></div>
        </form>
      )}

      {error && (
        <p role="alert" className="error-text task-checklist-error">
          {error}
        </p>
      )}
    </li>
  );
}

function toDateTimeLocal(value: string | null | undefined): string {
  if (!value) return '';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  const pad = (number: number) => String(number).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}
