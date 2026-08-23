import { useState, type FormEvent } from 'react';
import { Modal } from '../../components/Modal';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { todayIsoDate } from '../../lib/date';
import { useHousehold } from '../../app/HouseholdContext';
import type { CompletionMode, RoutinePhase, TaskInstance } from '../../lib/types';
import { useTaskCategories } from './useTaskCategories';

interface SubtaskDraft {
  title: string;
  required: boolean;
}

interface TaskFormModalProps {
  mode: 'create' | 'edit';
  task?: TaskInstance;
  initialTitle?: string;
  initialScheduledDate?: string;
  initialCalendarVisibility?: 'hidden' | 'special';
  onClose: () => void;
  onSaved: () => void;
}

export function TaskFormModal({
  mode,
  task,
  initialTitle,
  initialScheduledDate,
  initialCalendarVisibility,
  onClose,
  onSaved,
}: TaskFormModalProps) {
  const { members } = useHousehold();
  const { categories } = useTaskCategories();
  const [title, setTitle] = useState(task?.title ?? initialTitle ?? '');
  const [category, setCategory] = useState(task?.category ?? 'other');
  const [scheduledDate, setScheduledDate] = useState(
    task?.scheduled_date ?? initialScheduledDate ?? todayIsoDate(),
  );
  const formatLocalTime = (value: string | null | undefined) =>
    value
      ? new Intl.DateTimeFormat('en-GB', {
          timeZone: 'Asia/Tokyo',
          hour: '2-digit',
          minute: '2-digit',
          hour12: false,
        }).format(new Date(value))
      : '';
  const [dueLocalTime, setDueLocalTime] = useState(formatLocalTime(task?.due_at));
  const [calendarEndLocalTime, setCalendarEndLocalTime] = useState(
    formatLocalTime(task?.calendar_ends_at),
  );
  const [calendarVisibility, setCalendarVisibility] = useState<'hidden' | 'special'>(
    task?.calendar_visibility === 'special'
      ? 'special'
      : initialCalendarVisibility ?? 'hidden',
  );
  const [assigneeId, setAssigneeId] = useState(task?.planned_assignee_id ?? '');
  const [completionMode, setCompletionMode] = useState<CompletionMode>(
    task?.completion_mode ?? 'whole',
  );
  const [routinePhase, setRoutinePhase] = useState<RoutinePhase | ''>('');
  const [subtasks, setSubtasks] = useState<SubtaskDraft[]>([{ title: '', required: true }]);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [operationId] = useState(() => newOperationId());

  const isCalendarEvent = calendarVisibility === 'special';
  const modalTitle =
    mode === 'edit' ? '予定・やることを編集' : isCalendarEvent ? '予定を追加' : 'やることを追加';

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
    if (isCalendarEvent && dueLocalTime && !calendarEndLocalTime) {
      setError('開始時刻を入れる場合は終了時刻も入力してください。');
      return;
    }
    if (
      isCalendarEvent &&
      dueLocalTime &&
      calendarEndLocalTime &&
      calendarEndLocalTime <= dueLocalTime
    ) {
      setError('終了時刻は開始時刻より後にしてください。');
      return;
    }

    setSubmitting(true);
    try {
      if (mode === 'create') {
        const cleanSubtasks = subtasks
          .map((s, i) => ({ title: s.title.trim(), required: s.required, sort_order: i + 1 }))
          .filter((s) => s.title.length > 0);
        if (completionMode === 'subtasks' && cleanSubtasks.length === 0) {
          setError('チェックする項目を1つ以上入力してください。');
          setSubmitting(false);
          return;
        }
        await callEdgeFunction(EDGE_FUNCTIONS.createTask, {
          operation_id: operationId,
          title: title.trim(),
          category,
          scheduled_date: scheduledDate,
          due_local_time: dueLocalTime || undefined,
          calendar_end_local_time:
            isCalendarEvent && dueLocalTime ? calendarEndLocalTime || undefined : undefined,
          calendar_visibility: calendarVisibility,
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
          scheduled_date: scheduledDate,
          due_local_time: dueLocalTime || null,
          calendar_end_local_time:
            isCalendarEvent && dueLocalTime ? calendarEndLocalTime || null : null,
          category,
          calendar_visibility: calendarVisibility,
          planned_assignee_user_id: assigneeId || null,
        });
      }
      onSaved();
    } catch (err) {
      if (err instanceof FamilyOpsApiError && err.code === 'TASK_TERMINAL') {
        setError('この項目はすでに完了・キャンセル済みのため編集できません。');
      } else {
        setError(err instanceof FamilyOpsApiError ? err.message : '保存に失敗しました。');
      }
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Modal title={modalTitle} onClose={onClose} panelClassName="task-form-modal">
      <form onSubmit={handleSubmit} className="stack-form task-form">
        <label>
          何をする？
          <input
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder={isCalendarEvent ? '例：内藤歯科' : '例：保育園の持ち物を準備'}
            required
          />
        </label>

        <label>
          種類
          <select
            value={calendarVisibility}
            onChange={(e) =>
              setCalendarVisibility(e.target.value as 'hidden' | 'special')
            }
          >
            <option value="hidden">やること（おうちノート内）</option>
            <option value="special">予定（Google Calendarにも同期）</option>
          </select>
        </label>
        <p className="form-help">
          Googleから取り込んだ予定はGoogle側の開始・終了時刻をそのまま使います。ここで作る「予定」は、おうちノートを正としてGoogleへ同期します。
        </p>

        <label>
          日付
          <input
            type="date"
            value={scheduledDate}
            onChange={(e) => setScheduledDate(e.target.value)}
            required
          />
        </label>

        {isCalendarEvent ? (
          <div className="time-range-fields">
            <label>
              開始時刻（任意）
              <input
                type="time"
                value={dueLocalTime}
                onChange={(e) => setDueLocalTime(e.target.value)}
              />
            </label>
            <label>
              終了時刻{dueLocalTime ? '' : '（開始時刻を入れた場合）'}
              <input
                type="time"
                value={calendarEndLocalTime}
                onChange={(e) => setCalendarEndLocalTime(e.target.value)}
                disabled={!dueLocalTime}
                required={Boolean(dueLocalTime)}
              />
            </label>
            <p className="form-help time-range-help">時刻を入れない場合は終日予定として扱います。</p>
          </div>
        ) : (
          <label>
            やる時刻（任意）
            <input
              type="time"
              value={dueLocalTime}
              onChange={(e) => setDueLocalTime(e.target.value)}
            />
          </label>
        )}

        <label>
          カテゴリ
          <select value={category} onChange={(e) => setCategory(e.target.value)} required>
            {categories.map((item) => (
              <option key={item.code} value={item.code}>
                {item.label}
              </option>
            ))}
          </select>
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

        {mode === 'create' && !isCalendarEvent && (
          <>
            <label>
              時間帯（任意）
              <select
                value={routinePhase}
                onChange={(e) => setRoutinePhase(e.target.value as RoutinePhase | '')}
              >
                <option value="">指定なし</option>
                <option value="morning">朝</option>
                <option value="evening">夜</option>
                <option value="anytime">いつでも</option>
              </select>
            </label>
            <label>
              チェック方法
              <select
                value={completionMode}
                onChange={(e) => setCompletionMode(e.target.value as CompletionMode)}
              >
                <option value="whole">1回のチェックで完了</option>
                <option value="subtasks">項目ごとにチェック</option>
              </select>
            </label>
          </>
        )}

        {mode === 'create' && !isCalendarEvent && completionMode === 'subtasks' && (
          <fieldset className="subtask-editor">
            <legend>やることの中身</legend>
            <p className="form-help">作業するとき、この項目がそのままチェックリストに出ます。</p>
            {subtasks.map((s, i) => (
              <div className="subtask-row" key={i}>
                <input
                  value={s.title}
                  onChange={(e) => updateSubtaskRow(i, { title: e.target.value })}
                  placeholder={`項目 ${i + 1}`}
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
            <button type="button" className="secondary-button" onClick={addSubtaskRow}>
              ＋ 項目を追加
            </button>
          </fieldset>
        )}

        {error && (
          <p role="alert" className="error-text">
            {error}
          </p>
        )}
        <div className="modal-actions task-form-actions">
          <button type="submit" disabled={submitting}>
            {submitting ? '保存中…' : '保存'}
          </button>
          <button type="button" className="secondary-button" onClick={onClose} disabled={submitting}>
            キャンセル
          </button>
        </div>
      </form>
    </Modal>
  );
}
