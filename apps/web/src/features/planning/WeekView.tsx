import { Link } from 'react-router-dom';
import { useMemo, useState, type FormEvent } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { formatTimeJa } from '../../lib/date';
import { addDays, formatShortDate, localIsoDate, mondayOf } from './dateHelpers';
import { usePlanningData } from './usePlanningData';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import type { TaskInstance } from '../../lib/types';
import { useWeekSchedule } from './useWeekSchedule';

export function WeekView() {
  const { household, members, me, partner } = useHousehold();
  const [weekStart, setWeekStart] = useState(() => mondayOf(new Date()));
  const days = useMemo(
    () => Array.from({ length: 7 }, (_, i) => addDays(weekStart, i)),
    [weekStart],
  );
  const { loading, error, events, tasks, refresh } = usePlanningData(
    household?.id ?? null,
    localIsoDate(days[0]),
    localIsoDate(days[6]),
  );
  const canonical = useWeekSchedule(
    household?.id ?? null,
    localIsoDate(days[0]),
    localIsoDate(days[6]),
  );
  const [changingTask, setChangingTask] = useState<TaskInstance | null>(null);
  const nameFor = (id: string | null) =>
    members.find((member) => member.user_id === id)?.profile?.display_name ?? '';
  return (
    <main className="app-shell planning-page">
      <div className="today-header">
        <div>
          <p className="eyebrow">家族の見通し</p>
          <h1>今週</h1>
        </div>
        <Link className="button-link" to="/requests">
          お願いする
        </Link>
      </div>
      <div className="period-control">
        <button onClick={() => setWeekStart(addDays(weekStart, -7))}>前週</button>
        <strong>
          {formatShortDate(days[0])} 〜 {formatShortDate(days[6])}
        </strong>
        <button onClick={() => setWeekStart(addDays(weekStart, 7))}>次週</button>
      </div>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      {canonical.error && (
        <p role="alert" className="error-text">
          {canonical.error}
        </p>
      )}
      {canonical.schedule?.calendar_stale && (
        <p className="warning-banner">Googleカレンダーの同期が古いか、再接続が必要です。</p>
      )}
      {loading ? (
        <p role="status">読み込み中…</p>
      ) : (
        <div className="week-cards">
          {days.map((day) => {
            const date = localIsoDate(day);
            const dayEvents = events.filter((event) => event.date === date);
            return (
              <section className="week-day-card" key={date}>
                <h2>{formatShortDate(day)}</h2>
                {dayEvents.length === 0 ? (
                  <p className="empty-hint">予定なし</p>
                ) : (
                  <ul>
                    {dayEvents.map((event) => {
                      const task =
                        event.kind === 'task' ? tasks.find((item) => item.id === event.id) : null;
                      const hasConflict = Boolean(
                        task &&
                        canonical.schedule?.assignments.some(
                          (item) => item.task_instance_id === task.id && item.has_conflict,
                        ),
                      );
                      return (
                        <li
                          key={`${event.kind}-${event.id}`}
                          className={event.kind === 'calendar' ? 'calendar-event' : 'task-event'}
                        >
                          <span>{event.time ? formatTimeJa(event.time) : '終日'}</span>
                          <strong>{event.title}</strong>
                          {hasConflict && <span className="error-text">⚠ 予定と重複</span>}
                          {event.assigneeId && <small>担当: {nameFor(event.assigneeId)}</small>}
                          {task?.planned_assignee_id === me?.user_id && partner && (
                            <button
                              className="inline-link-button"
                              type="button"
                              onClick={() => setChangingTask(task ?? null)}
                            >
                              担当を相談
                            </button>
                          )}
                        </li>
                      );
                    })}
                  </ul>
                )}
                <Link to={`/requests?date=${date}`} className="day-action">
                  別のお願いをする
                </Link>
              </section>
            );
          })}
        </div>
      )}
      {changingTask && partner && (
        <AssignmentChangeForm
          task={changingTask}
          partnerName={partner.profile?.display_name ?? 'パートナー'}
          partnerId={partner.user_id}
          onClose={() => setChangingTask(null)}
          onSaved={async () => {
            setChangingTask(null);
            await refresh();
          }}
        />
      )}
    </main>
  );
}

function AssignmentChangeForm({
  task,
  partnerName,
  partnerId,
  onClose,
  onSaved,
}: {
  task: TaskInstance;
  partnerName: string;
  partnerId: string;
  onClose: () => void;
  onSaved: () => Promise<void>;
}) {
  const [scope, setScope] = useState<'once' | 'this_week'>('once');
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState(false);
  const [previewing, setPreviewing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.createAssignmentChangeRequest, {
        operation_id: newOperationId(),
        task_id: task.id,
        recipient_user_id: partnerId,
        scope,
        shared_message: message,
      });
      await onSaved();
    } catch (err) {
      setError(
        err instanceof FamilyOpsApiError ? err.message : '担当変更のお願いを送れませんでした。',
      );
    } finally {
      setBusy(false);
    }
  };
  const scopeLabel = scope === 'this_week' ? '今週だけ' : '今回だけ';
  return (
    <div className="modal-backdrop" role="presentation">
      <form className="modal-panel stack-form" onSubmit={submit}>
        <div className="modal-header">
          <h2>{task.title}の担当を相談</h2>
          <button type="button" className="modal-close" onClick={onClose}>
            ×
          </button>
        </div>
        <p>相手が「引き受ける」を押すまで、担当は変わりません。</p>
        <Link className="secondary-button" to="/settings/routines" onClick={onClose}>
          定常ルールを変更
        </Link>
        {!previewing ? (
          <>
            <label>
              変更の範囲
              <select
                value={scope}
                onChange={(event) => setScope(event.target.value as 'once' | 'this_week')}
              >
                <option value="once">今回だけ</option>
                <option value="this_week">今週だけ</option>
              </select>
            </label>
            <label>
              {partnerName}へ送る文面
              <textarea
                value={message}
                onChange={(event) => setMessage(event.target.value)}
                placeholder="今日ちょっと遅くなるので、お願いできる？"
              />
            </label>
            <button type="button" disabled={busy} onClick={() => setPreviewing(true)}>
              LINE送信内容を確認
            </button>
          </>
        ) : (
          <section className="line-sender-preview" aria-label="LINE担当変更プレビュー">
            <p className="line-preview-kicker">LINE · 送る側の確認</p>
            <h3>この内容で送りますか？</h3>
            <p className="line-preview-message">{message || '担当をお願いしてもいい？'}</p>
            <p className="line-preview-meta">
              {task.title} / {scopeLabel} / 自分 → {partnerName}
            </p>
            <p className="empty-hint">送るまでは相手に通知されません。</p>
            <div className="modal-actions">
              <button
                type="button"
                className="secondary-button"
                disabled={busy}
                onClick={() => setPreviewing(false)}
              >
                編集
              </button>
              <button disabled={busy}>{busy ? '送信中…' : 'LINEで送る'}</button>
            </div>
          </section>
        )}
        {error && (
          <p role="alert" className="error-text">
            {error}
          </p>
        )}
      </form>
    </div>
  );
}
