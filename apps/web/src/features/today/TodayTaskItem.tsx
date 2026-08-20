import { useState } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import type { TaskInstance, TaskSubtaskInstance } from '../../lib/types';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';

interface TodayTaskItemProps {
  task: TaskInstance;
  subtasks: TaskSubtaskInstance[];
  members: HouseholdMemberWithProfile[];
  hasPartner: boolean;
  onEdit: (task: TaskInstance) => void;
  onChanged: () => void;
}

function assigneeLabel(task: TaskInstance, members: HouseholdMemberWithProfile[]): string {
  if (!task.planned_assignee_id) return '未定';
  const member = members.find((m) => m.user_id === task.planned_assignee_id);
  return member?.profile?.display_name ?? task.planned_assignee_id;
}

// completion_actor records who *physically* did the task, which is
// independent of who it was planned for (e.g. one partner marking a task
// complete on the other's behalf). Only offer the "partner did it" choice
// when a partner actually exists in the household.
export function TodayTaskItem({ task, subtasks, members, hasPartner, onEdit, onChanged }: TodayTaskItemProps) {
  const [expanded, setExpanded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [actor, setActor] = useState<'self' | 'partner'>('self');

  async function withOperation(fn: (operationId: string) => Promise<unknown>) {
    setError(null);
    setBusy(true);
    const operationId = newOperationId();
    try {
      await fn(operationId);
      onChanged();
    } catch (err) {
      if (err instanceof FamilyOpsApiError && err.code === 'TASK_TERMINAL') {
        setError('このタスクはすでに完了・キャンセル済みです。');
      } else {
        setError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。');
      }
    } finally {
      setBusy(false);
    }
  }

  function handleComplete() {
    withOperation((operationId) =>
      callEdgeFunction(EDGE_FUNCTIONS.completeTask, {
        operation_id: operationId,
        task_id: task.id,
        completion_actor: actor,
        complete_remaining_subtasks: task.completion_mode === 'subtasks' ? true : undefined,
      }),
    );
  }

  function handleCancel() {
    withOperation((operationId) =>
      callEdgeFunction(EDGE_FUNCTIONS.cancelTask, { operation_id: operationId, task_id: task.id }),
    );
  }

  function handleToggleSubtask(subtask: TaskSubtaskInstance) {
    withOperation((operationId) =>
      callEdgeFunction(EDGE_FUNCTIONS.setSubtaskCompletion, {
        operation_id: operationId,
        subtask_instance_id: subtask.id,
        completed: !subtask.is_completed,
        completion_actor: actor,
      }),
    );
  }

  const requiredRemaining = subtasks.filter((s) => s.required && !s.is_completed).length;

  return (
    <li className="task-item">
      <div className="task-item-main">
        <div className="task-item-title">
          <strong>{task.title}</strong>
          <span className="task-item-meta">
            {task.due_at ? new Date(task.due_at).toLocaleTimeString('ja-JP', { hour: '2-digit', minute: '2-digit' }) : ''}
            {' · '}
            {assigneeLabel(task, members)}
          </span>
        </div>
        <div className="task-item-actions">
          {hasPartner && (
            <select
              aria-label="実施者"
              value={actor}
              onChange={(e) => setActor(e.target.value as 'self' | 'partner')}
              disabled={busy}
            >
              <option value="self">自分</option>
              <option value="partner">パートナー</option>
            </select>
          )}
          {task.completion_mode === 'subtasks' ? (
            <button type="button" onClick={() => setExpanded((v) => !v)}>
              {expanded ? '閉じる' : `サブタスク (${subtasks.length - requiredRemaining}/${subtasks.length})`}
            </button>
          ) : null}
          <button type="button" onClick={handleComplete} disabled={busy}>
            完了
          </button>
          <button type="button" onClick={() => onEdit(task)} disabled={busy}>
            編集
          </button>
          <button type="button" onClick={handleCancel} disabled={busy}>
            キャンセル
          </button>
        </div>
      </div>
      {expanded && task.completion_mode === 'subtasks' && (
        <ul className="subtask-list">
          {subtasks.map((s) => (
            <li key={s.id}>
              <label>
                <input
                  type="checkbox"
                  checked={s.is_completed}
                  disabled={busy}
                  onChange={() => handleToggleSubtask(s)}
                />
                {s.title}
                {s.required ? '' : '（任意）'}
              </label>
            </li>
          ))}
        </ul>
      )}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </li>
  );
}
