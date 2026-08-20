import { useState, type FormEvent } from 'react';
import { Modal } from '../../components/Modal';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { todayIsoDate } from '../../lib/date';
import { useHousehold } from '../../app/HouseholdContext';
import type { CompletionMode, RoutinePhase, TaskInstance } from '../../lib/types';

interface SubtaskDraft {
  title: string;
  required: boolean;
}

interface TaskFormModalProps {
  mode: 'create' | 'edit';
  task?: TaskInstance;
  /**
   * Sol re-review #3 fix (P1-1): create-mode-only starting title, used by
   * the pending-action "編集してPWAフォームへ" fallback (a needs_pwa_review
   * draft's raw LINE text has no execution path of its own — this pre-fills
   * the normal task form with it as a correction starting point instead of
   * a dead end).
   */
  initialTitle?: string;
  onClose: () => void;
  onSaved: () => void;
}

// create-task accepts the full shape (category, date, completion mode,
// subtasks); edit-task's contract only accepts {title, due_local_time,
// planned_assignee_user_id} — so in edit mode we simply don't render the
// fields the backend won't accept, rather than sending them and hoping
// they're ignored.
export function TaskFormModal({ mode, task, initialTitle, onClose, onSaved }: TaskFormModalProps) {
  const { members } = useHousehold();
  const [title, setTitle] = useState(task?.title ?? initialTitle ?? '');
  const [category, setCategory] = useState(task?.category ?? '');
  const [scheduledDate, setScheduledDate] = useState(task?.scheduled_date ?? todayIsoDate());
  const [dueLocalTime, setDueLocalTime] = useState('');
  const [assigneeId, setAssigneeId] = useState(task?.planned_assignee_id ?? '');
  const [completionMode, setCompletionMode] = useState<CompletionMode>(task?.completion_mode ?? 'whole');
  const [routinePhase, setRoutinePhase] = useState<RoutinePhase | ''>('');
  const [subtasks, setSubtasks] = useState<SubtaskDraft[]>([{ title: '', required: true }]);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [operationId] = useState(() => newOperationId());

  function addSubtaskRow() {
    setSubtasks((prev) => [...prev, { title: '', required: true }]);
  }

  function updateSubtaskRow(index: number, patch: Partial<SubtaskDraft>) {
    setSubtasks((prev) => prev.map((s, i) => (i === index ? { ...s, ...patch } : s)));
  }

  function removeSubtaskRow(index: number) {
    setSubtasks((prev) => prev.filter((_, i) => i !== index));
  }

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);

    if (!title.trim()) {
      setError('タイトルを入力してください。');
      return;
    }

    setSubmitting(true);
    try {
      if (mode === 'create') {
        const cleanSubtasks = subtasks
          .map((s, i) => ({ title: s.title.trim(), required: s.required, sort_order: i + 1 }))
          .filter((s) => s.title.length > 0);
        if (completionMode === 'subtasks' && cleanSubtasks.length === 0) {
          setError('サブタスクを1つ以上入力してください。');
          setSubmitting(false);
          return;
        }
        await callEdgeFunction(EDGE_FUNCTIONS.createTask, {
          operation_id: operationId,
          title: title.trim(),
          category: category.trim() || 'other',
          scheduled_date: scheduledDate,
          due_local_time: dueLocalTime || undefined,
          planned_assignee_user_id: assigneeId || undefined,
          completion_mode: completionMode,
          routine_phase: routinePhase || undefined,
          subtasks: completionMode === 'subtasks' ? cleanSubtasks : undefined,
        });
      } else if (task) {
        await callEdgeFunction(EDGE_FUNCTIONS.editTask, {
          operation_id: operationId,
          task_id: task.id,
          title: title.trim(),
          due_local_time: dueLocalTime || undefined,
          planned_assignee_user_id: assigneeId || undefined,
        });
      }
      onSaved();
    } catch (err) {
      if (err instanceof FamilyOpsApiError && err.code === 'TASK_TERMINAL') {
        setError('このタスクはすでに完了・キャンセル済みのため編集できません。');
      } else {
        setError(err instanceof FamilyOpsApiError ? err.message : '保存に失敗しました。');
      }
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Modal title={mode === 'create' ? 'タスクを作成' : 'タスクを編集'} onClose={onClose}>
      <form onSubmit={handleSubmit} className="stack-form">
        <label>
          タイトル
          <input value={title} onChange={(e) => setTitle(e.target.value)} required />
        </label>

        {mode === 'create' && (
          <>
            <label>
              カテゴリ
              <input
                value={category}
                onChange={(e) => setCategory(e.target.value)}
                placeholder="例: meal, cleaning, other"
                required
              />
            </label>
            <label>
              日付
              <input
                type="date"
                value={scheduledDate}
                onChange={(e) => setScheduledDate(e.target.value)}
                required
              />
            </label>
            <label>
              時間帯（任意）
              <select value={routinePhase} onChange={(e) => setRoutinePhase(e.target.value as RoutinePhase | '')}>
                <option value="">指定なし</option>
                <option value="morning">朝</option>
                <option value="evening">夜</option>
                <option value="anytime">いつでも</option>
              </select>
            </label>
            <label>
              完了方法
              <select
                value={completionMode}
                onChange={(e) => setCompletionMode(e.target.value as CompletionMode)}
              >
                <option value="whole">まとめて完了</option>
                <option value="subtasks">サブタスクごとに完了</option>
              </select>
            </label>
          </>
        )}

        <label>
          期限時刻（任意）
          <input type="time" value={dueLocalTime} onChange={(e) => setDueLocalTime(e.target.value)} />
        </label>

        <label>
          担当者（任意）
          <select value={assigneeId} onChange={(e) => setAssigneeId(e.target.value)}>
            <option value="">未定</option>
            {members.map((m) => (
              <option key={m.user_id} value={m.user_id}>
                {m.profile?.display_name ?? m.user_id}
              </option>
            ))}
          </select>
        </label>

        {mode === 'create' && completionMode === 'subtasks' && (
          <fieldset>
            <legend>サブタスク</legend>
            {subtasks.map((s, i) => (
              <div className="subtask-row" key={i}>
                <input
                  value={s.title}
                  onChange={(e) => updateSubtaskRow(i, { title: e.target.value })}
                  placeholder={`サブタスク ${i + 1}`}
                />
                <label className="inline-check">
                  <input
                    type="checkbox"
                    checked={s.required}
                    onChange={(e) => updateSubtaskRow(i, { required: e.target.checked })}
                  />
                  必須
                </label>
                {subtasks.length > 1 && (
                  <button type="button" onClick={() => removeSubtaskRow(i)} aria-label="削除">
                    削除
                  </button>
                )}
              </div>
            ))}
            <button type="button" onClick={addSubtaskRow}>
              + サブタスクを追加
            </button>
          </fieldset>
        )}

        {error && (
          <p role="alert" className="error-text">
            {error}
          </p>
        )}
        <div className="modal-actions">
          <button type="submit" disabled={submitting}>
            {submitting ? '保存中…' : '保存'}
          </button>
          <button type="button" onClick={onClose} disabled={submitting}>
            キャンセル
          </button>
        </div>
      </form>
    </Modal>
  );
}
