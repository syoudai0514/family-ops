import { useEffect, useMemo, useState, type FormEvent } from 'react';
import { Modal } from '../../components/Modal';
import { FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { useCommandAttempt } from '../../lib/useCommandAttempt';
import { todayIsoDate } from '../../lib/date';
import { useHousehold } from '../../app/HouseholdContext';
import type { CompletionMode, RoutinePhase, TaskInstance } from '../../lib/types';
import { useTaskCategories } from './useTaskCategories';
import { clearTaskFormDraft, readTaskFormDraft, saveTaskFormDraft } from './taskFormDraft';
import {
  ALL_DAY_REMINDER_OPTIONS,
  canRemindWithGoogle,
  defaultReminders,
  effectiveReminderChannel,
  emptyScheduleDetails,
  MAX_REMINDERS,
  reminderLabel,
  reminderOffsets,
  TIMED_REMINDER_OPTIONS,
  validateScheduleFiles,
  type ScheduleDetails,
} from '../planning/scheduleDetails';
import { uploadScheduleAttachment } from '../planning/scheduleAttachments';
import { useFamilyCalendarWriteTarget } from '../planning/useFamilyCalendarWriteTarget';

interface SubtaskDraft {
  title: string;
  required: boolean;
}

interface TaskFormModalProps {
  mode: 'create' | 'edit';
  task?: TaskInstance & { scheduler_details?: ScheduleDetails | null };
  initialTitle?: string;
  initialScheduledDate?: string;
  initialCalendarVisibility?: 'hidden' | 'special';
  onClose: () => void;
  onSaved: () => void;
}

export function TaskFormModal(props: TaskFormModalProps) {
  const { household, me } = useHousehold();
  // Scope the live form as well as its stored draft. If auth/membership changes
  // while it is open, old fields must not be saved into the new owner's draft.
  return (
    <TaskFormModalContent
      key={`${me?.user_id ?? ''}:${household?.id ?? ''}:${props.task?.id ?? 'create'}`}
      {...props}
    />
  );
}

function TaskFormModalContent({
  mode,
  task,
  initialTitle,
  initialScheduledDate,
  initialCalendarVisibility,
  onClose,
  onSaved,
}: TaskFormModalProps) {
  const { members, household, me } = useHousehold();
  const runCommand = useCommandAttempt();
  const { categories } = useTaskCategories();
  const userId = me?.user_id;
  const householdId = household?.id;
  const draftScope = useMemo(
    () => (userId && householdId ? { userId, householdId } : null),
    [userId, householdId],
  );
  const draft = useMemo(
    () => (mode === 'create' ? readTaskFormDraft(draftScope) : null),
    [mode, draftScope],
  );
  const [title, setTitle] = useState(task?.title ?? initialTitle ?? draft?.title ?? '');
  const [category, setCategory] = useState(task?.category ?? draft?.category ?? 'other');
  const [scheduledDate, setScheduledDate] = useState(
    task?.scheduled_date ?? initialScheduledDate ?? draft?.scheduledDate ?? todayIsoDate(),
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
  const [dueLocalTime, setDueLocalTime] = useState(
    task?.due_at
      ? formatLocalTime(task.due_at)
      : ((mode === 'create' ? draft?.dueLocalTime : '') ?? ''),
  );
  const [calendarEndLocalTime, setCalendarEndLocalTime] = useState(
    task?.due_at && task.calendar_ends_at
      ? formatLocalTime(task.calendar_ends_at)
      : ((mode === 'create' ? draft?.calendarEndLocalTime : '') ?? ''),
  );
  const [calendarVisibility, setCalendarVisibility] = useState<'hidden' | 'special'>(
    task?.calendar_visibility === 'special'
      ? 'special'
      : (initialCalendarVisibility ?? draft?.calendarVisibility ?? 'hidden'),
  );
  const [assigneeId, setAssigneeId] = useState(
    task?.planned_assignee_id ?? draft?.assigneeId ?? '',
  );
  const [completionMode, setCompletionMode] = useState<CompletionMode>(
    task?.completion_mode ?? draft?.completionMode ?? 'whole',
  );
  const [routinePhase, setRoutinePhase] = useState<RoutinePhase | ''>(draft?.routinePhase ?? '');
  const [subtasks, setSubtasks] = useState<SubtaskDraft[]>(
    draft?.subtasks?.length ? draft.subtasks : [{ title: '', required: true }],
  );
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [details, setDetails] = useState<ScheduleDetails>(() =>
    task?.scheduler_details
      ? (() => {
          const saved = { ...emptyScheduleDetails(task.scheduled_date), ...task.scheduler_details };
          return { ...saved, reminders: reminderOffsets(saved) };
        })()
      : mode === 'edit'
        ? { ...emptyScheduleDetails(task?.scheduled_date ?? todayIsoDate()), reminders: [] }
        : mode === 'create' && draft?.schedulerDetails
        ? {
            ...draft.schedulerDetails,
            ends_on:
              initialScheduledDate && initialScheduledDate !== draft.scheduledDate
                ? initialScheduledDate
                : draft.schedulerDetails.ends_on,
          }
        : emptyScheduleDetails(task?.scheduled_date ?? initialScheduledDate ?? todayIsoDate()),
  );
  const [files, setFiles] = useState<File[]>([]);
  const [savedTaskId, setSavedTaskId] = useState<string | null>(null);

  const isCalendarEvent = calendarVisibility === 'special';
  const isAllDay = !dueLocalTime;
  // Until someone picks reminders, a new 予定 gets the same default as LINE / AI入力.
  const reminders = Array.isArray(details.reminders)
    ? details.reminders
    : isCalendarEvent
      ? defaultReminders(!isAllDay, household)
      : [];
  const googleWriteTarget = useFamilyCalendarWriteTarget();
  const googleEligible = canRemindWithGoogle({
    googleWriteTarget,
    isCalendarEvent,
    startTime: dueLocalTime,
    endTime: calendarEndLocalTime,
  });
  const reminderChannel = effectiveReminderChannel(details.reminder_channel, googleEligible);
  const reminderOptions = [
    ...new Set([...(isAllDay ? ALL_DAY_REMINDER_OPTIONS : TIMED_REMINDER_OPTIONS), ...reminders]),
  ].sort((a, b) => a - b);
  function toggleReminder(minutes: number, checked: boolean) {
    setDetails((d) => ({
      ...d,
      reminder_minutes: null,
      reminders: checked
        ? [...reminders.filter((value) => value !== minutes), minutes].sort((a, b) => a - b)
        : reminders.filter((value) => value !== minutes),
    }));
  }
  const modalTitle =
    mode === 'edit' ? '予定・やることを編集' : isCalendarEvent ? '予定を追加' : 'やることを追加';
  function closeForm() {
    if (savedTaskId) {
      if (mode === 'create') clearTaskFormDraft(draftScope);
      onSaved();
    } else onClose();
  }

  useEffect(() => {
    if (mode !== 'create') return;
    saveTaskFormDraft(
      {
        title,
        category,
        scheduledDate,
        dueLocalTime,
        calendarEndLocalTime,
        calendarVisibility,
        assigneeId,
        completionMode,
        routinePhase,
        subtasks,
        schedulerDetails: details,
      },
      draftScope,
    );
  }, [
    mode,
    draftScope,
    title,
    category,
    scheduledDate,
    dueLocalTime,
    calendarEndLocalTime,
    calendarVisibility,
    assigneeId,
    completionMode,
    routinePhase,
    subtasks,
    details,
  ]);

  function addSubtaskRow() {
    setSubtasks((prev) => [...prev, { title: '', required: true }]);
  }

  function updateSubtaskRow(index: number, patch: Partial<SubtaskDraft>) {
    setSubtasks((prev) => prev.map((s, i) => (i === index ? { ...s, ...patch } : s)));
  }

  function removeSubtaskRow(index: number) {
    setSubtasks((prev) => prev.filter((_, i) => i !== index));
  }

  async function handleDelete() {
    if (!task) return;
    if (
      !window.confirm(
        `「${task.title}」を削除しますか？\n削除すると元に戻せません。予定ならカレンダーからも消えます。${
          details.repeat_frequency !== 'none' ? '\n繰り返しのほかの回は残ります。' : ''
        }`,
      )
    )
      return;
    setError(null);
    setSubmitting(true);
    try {
      await runCommand(`task-form:cancel:${task.id}:r${task.revision ?? 1}`, EDGE_FUNCTIONS.cancelTask, (operationId) => ({
        operation_id: operationId,
        task_id: task.id,
      }));
      onSaved();
    } catch (err) {
      setError(err instanceof Error ? err.message : '削除できませんでした。');
    } finally {
      setSubmitting(false);
    }
  }

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);

    if (!title.trim()) {
      setError('タイトルを入力してください。');
      return;
    }
    if (
      isCalendarEvent &&
      dueLocalTime &&
      calendarEndLocalTime &&
      details.ends_on === scheduledDate &&
      calendarEndLocalTime <= dueLocalTime
    ) {
      setError('終了時刻は開始時刻より後にしてください。');
      return;
    }
    if (details.ends_on < scheduledDate) {
      setError('終了日は開始日以降にしてください。');
      return;
    }
    if (details.repeat_frequency !== 'none' && !details.repeat_until) {
      setError('繰り返しの終了日を選んでください。');
      return;
    }
    const fileError = validateScheduleFiles(files);
    if (fileError) {
      setError(fileError);
      return;
    }

    setSubmitting(true);
    try {
      let persistedId = savedTaskId ?? task?.id ?? null;
      if (!savedTaskId && mode === 'create') {
        const cleanSubtasks = subtasks
          .map((s, i) => ({ title: s.title.trim(), required: s.required, sort_order: i + 1 }))
          .filter((s) => s.title.length > 0);
        if (completionMode === 'subtasks' && cleanSubtasks.length === 0) {
          setError('チェックする項目を1つ以上入力してください。');
          setSubmitting(false);
          return;
        }
        const result = await runCommand<{ task_id: string }>(
          'task-form:create',
          EDGE_FUNCTIONS.createTask,
          (operationId) => ({
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
            scheduler_details: {
              ...details,
              reminder_minutes: null,
              reminders,
              reminder_channel: reminderChannel,
              ends_on: isCalendarEvent ? details.ends_on : scheduledDate,
            },
          }),
        );
        if (!result.task_id)
          throw new Error('保存結果を確認できませんでした。もう一度保存してください。');
        persistedId = result.task_id;
        setSavedTaskId(persistedId);
      } else if (!savedTaskId && task) {
        await runCommand(
          `task-form:edit:${task.id}:r${task.revision ?? 1}`,
          EDGE_FUNCTIONS.editTask,
          (operationId) => ({
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
            expected_revision: task.revision ?? 1,
            scheduler_details: {
              ...details,
              reminder_minutes: null,
              reminders,
              reminder_channel: reminderChannel,
              ends_on: isCalendarEvent ? details.ends_on : scheduledDate,
            },
          }),
        );
        setSavedTaskId(task.id);
      }
      if (files.length && !household)
        throw new Error('家庭情報を確認できません。添付はまだ保存されていません。');
      if (persistedId && household)
        for (const file of files) {
          await uploadScheduleAttachment(household.id, persistedId, file);
          setFiles((current) => current.filter((item) => item !== file));
        }
      if (mode === 'create') clearTaskFormDraft(draftScope);
      onSaved();
    } catch (err) {
      if (err instanceof FamilyOpsApiError && err.code === 'TASK_TERMINAL') {
        setError('この項目はすでに完了・キャンセル済みのため編集できません。');
      } else {
        const message = err instanceof Error ? err.message : '保存に失敗しました。';
        setError(
          savedTaskId
            ? `予定は保存済みです。添付の保存に失敗しました: ${message}。もう一度保存すると添付だけ再試行します。`
            : message,
        );
      }
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Modal title={modalTitle} onClose={closeForm} panelClassName="task-form-modal">
      <form onSubmit={handleSubmit} className="stack-form task-form">
        {savedTaskId && <p role="status">予定は保存済みです。残りの添付を保存してください。</p>}
        <fieldset disabled={submitting || Boolean(savedTaskId)} className="schedule-form-fields">
          {mode === 'create' && (
            <p className="form-help">
              閉じても入力途中の下書きはこの端末内に残ります。保存が完了したときだけ下書きを消します。
            </p>
          )}
          <h3 className="form-section-title">1 基本</h3>
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
              onChange={(e) => setCalendarVisibility(e.target.value as 'hidden' | 'special')}
            >
              <option value="hidden">やること（おうちノート内）</option>
              <option value="special">予定（Google Calendarにも同期）</option>
            </select>
          </label>
          <p className="form-help">
            Googleから取り込んだ予定はGoogle側の開始・終了時刻をそのまま使います。ここで作る「予定」は、おうちノートを正としてGoogleへ同期します。
          </p>

          <h3 className="form-section-title">2 いつ・誰が</h3>
          <label>
            日付
            <input
              type="date"
              value={scheduledDate}
              onChange={(e) => {
                const date = e.target.value;
                setScheduledDate(date);
                setDetails((d) => ({
                  ...d,
                  ends_on: d.ends_on === scheduledDate || d.ends_on < date ? date : d.ends_on,
                }));
              }}
              required
            />
          </label>

          {isCalendarEvent ? (
            <>
              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={!dueLocalTime}
                  onChange={(e) => {
                    if (e.target.checked) {
                      setDueLocalTime('');
                      setCalendarEndLocalTime('');
                    } else setDueLocalTime('09:00');
                  }}
                />
                終日
              </label>
              <label>
                終了日
                <input
                  type="date"
                  value={details.ends_on}
                  min={scheduledDate}
                  onChange={(e) => setDetails((d) => ({ ...d, ends_on: e.target.value }))}
                  required
                />
              </label>
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
                  終了時刻（任意）
                  <input
                    type="time"
                    value={calendarEndLocalTime}
                    onChange={(e) => setCalendarEndLocalTime(e.target.value)}
                    disabled={!dueLocalTime}
                  />
                </label>
                <p className="form-help time-range-help">
                  終了時刻を入れない場合はGoogleに終日予定として表示します。開始時刻がある場合はタイトルの先頭に時刻を付けます。
                </p>
              </div>
            </>
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

          {(isCalendarEvent || reminders.length > 0) && (
            <fieldset className="reminder-picker">
              <legend>通知</legend>
              {googleWriteTarget && isCalendarEvent && (
                <div className="reminder-channel" role="radiogroup" aria-label="通知の方法">
                  <label className="checkbox-row">
                    <input
                      type="radio"
                      name="reminder-channel"
                      checked={reminderChannel === 'google'}
                      disabled={!googleEligible}
                      onChange={() => setDetails((d) => ({ ...d, reminder_channel: 'google' }))}
                    />
                    Googleカレンダーの通知
                  </label>
                  <label className="checkbox-row">
                    <input
                      type="radio"
                      name="reminder-channel"
                      checked={reminderChannel === 'app'}
                      onChange={() => setDetails((d) => ({ ...d, reminder_channel: 'app' }))}
                    />
                    おうちノートから通知（スマホの通知・LINE）
                  </label>
                  {!googleEligible && (
                    <p className="form-help">
                      Googleカレンダーの通知は、開始と終了の時刻がある予定で選べます。時刻のない予定や開始時刻だけの予定は、Googleでは終日の予定になるため、おうちノートから通知します。
                    </p>
                  )}
                </div>
              )}
              {reminderChannel === 'google' ? (
                <p className="form-help">
                  それぞれのGoogleカレンダーの通知設定（家族カレンダーの通知）で届きます。おうちノートからは送りません。
                </p>
              ) : (
                <>
                  <p className="form-help">{MAX_REMINDERS}件まで選べます。</p>
                  <div className="reminder-options">
                    {reminderOptions.map((minutes) => {
                      const checked = reminders.includes(minutes);
                      return (
                        <label key={minutes} className="reminder-chip">
                          <input
                            type="checkbox"
                            checked={checked}
                            disabled={!checked && reminders.length >= MAX_REMINDERS}
                            onChange={(e) => toggleReminder(minutes, e.target.checked)}
                          />
                          {reminderLabel(minutes, isAllDay)}
                        </label>
                      );
                    })}
                  </div>
                  <p className="form-help">
                    {reminders.length === 0
                      ? '通知しません。'
                      : `${reminders.map((minutes) => reminderLabel(minutes, isAllDay)).join('・')}に通知します。`}
                    参加する人（未選択なら家族全員）に届きます。通知をオンにした端末にはスマホの通知で、それ以外の人にはLINEで届きます。
                  </p>
                </>
              )}
            </fieldset>
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
            <h3 className="form-section-title">3 チェック内容</h3>
          )}
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

          <details className="schedule-options" open={isCalendarEvent || undefined}>
            <summary>予定の詳細・共有</summary>
            <div className="stack-form">
              <label>
                場所
                <input
                  value={details.location}
                  onChange={(e) => setDetails((d) => ({ ...d, location: e.target.value }))}
                  maxLength={1000}
                />
              </label>
              <label>
                URL
                <input
                  type="url"
                  value={details.url}
                  onChange={(e) => setDetails((d) => ({ ...d, url: e.target.value }))}
                  maxLength={2048}
                />
              </label>
              <label>
                メモ
                <textarea
                  rows={6}
                  value={details.notes}
                  onChange={(e) => setDetails((d) => ({ ...d, notes: e.target.value }))}
                  maxLength={20000}
                  placeholder="園からのお知らせや持ち物など、そのまま残せます"
                />
              </label>
              <label>
                チェックリスト（1行に1項目）
                <textarea
                  rows={3}
                  value={details.checklist.join('\n')}
                  onChange={(e) =>
                    setDetails((d) => ({
                      ...d,
                      checklist: e.target.value.split('\n'),
                      checked_items: [],
                    }))
                  }
                />
              </label>
              <label>
                ラベルの色
                <input
                  type="color"
                  value={details.label_color}
                  onChange={(e) => setDetails((d) => ({ ...d, label_color: e.target.value }))}
                />
              </label>
              <fieldset>
                <legend>参加する人</legend>
                {members.map((member) => (
                  <label key={member.user_id} className="checkbox-row">
                    <input
                      type="checkbox"
                      checked={details.participants.includes(member.user_id)}
                      onChange={(e) =>
                        setDetails((d) => ({
                          ...d,
                          participants: e.target.checked
                            ? [...d.participants, member.user_id]
                            : d.participants.filter((id) => id !== member.user_id),
                        }))
                      }
                    />
                    {member.profile?.display_name ??
                      (member.family_role === 'papa' ? 'パパ' : 'ママ')}
                  </label>
                ))}
              </fieldset>
              <label>
                繰り返し
                <select
                  value={details.repeat_frequency}
                  disabled={mode === 'edit'}
                  onChange={(e) =>
                    setDetails((d) => ({
                      ...d,
                      repeat_frequency: e.target.value as ScheduleDetails['repeat_frequency'],
                    }))
                  }
                >
                  <option value="none">繰り返さない</option>
                  <option value="daily">毎日</option>
                  <option value="weekly">毎週</option>
                  <option value="monthly">毎月</option>
                </select>
              </label>
              {details.repeat_frequency !== 'none' && (
                <label>
                  繰り返しの終了日
                  <input
                    type="date"
                    value={details.repeat_until ?? ''}
                    min={scheduledDate}
                    max={new Date(
                      new Date(`${scheduledDate || todayIsoDate()}T12:00:00Z`).getTime() +
                        366 * 86400000,
                    )
                      .toISOString()
                      .slice(0, 10)}
                    disabled={mode === 'edit'}
                    onChange={(e) => setDetails((d) => ({ ...d, repeat_until: e.target.value }))}
                    required
                  />
                </label>
              )}
              {mode === 'edit' && details.repeat_frequency !== 'none' && (
                <p className="form-help">この回だけを編集します。</p>
              )}
              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={details.pinned}
                  onChange={(e) => setDetails((d) => ({ ...d, pinned: e.target.checked }))}
                />
                メモとして目立たせる
              </label>
              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={details.countdown}
                  onChange={(e) => setDetails((d) => ({ ...d, countdown: e.target.checked }))}
                />
                予定までの日数を表示
              </label>
            </div>
          </details>
        </fieldset>
        <label>
          添付ファイル（画像・PDF・テキスト / 1件10MBまで）
          <input
            type="file"
            multiple
            accept="image/jpeg,image/png,image/webp,image/heic,image/heif,application/pdf,text/plain"
            disabled={submitting}
            onChange={(e) => {
              const selected = Array.from(e.target.files ?? []);
              const invalid = validateScheduleFiles(selected);
              if (invalid) setError(invalid);
              else {
                setError(null);
                setFiles(selected);
              }
            }}
          />
        </label>
        {files.length > 0 && (
          <ul className="schedule-file-list">
            {files.map((file) => (
              <li key={`${file.name}:${file.lastModified}`}>{file.name}</li>
            ))}
          </ul>
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
          <button
            type="button"
            className="secondary-button"
            onClick={closeForm}
            disabled={submitting}
          >
            閉じる
          </button>
          {mode === 'edit' && task && !savedTaskId && (
            <button
              type="button"
              className="danger-button task-form-delete"
              onClick={() => void handleDelete()}
              disabled={submitting}
            >
              削除
            </button>
          )}
        </div>
      </form>
    </Modal>
  );
}
