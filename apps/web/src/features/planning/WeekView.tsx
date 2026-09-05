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
import { assigneeToken, buildCalendarProjection, transportTokens, type CalendarProjectionItem } from './calendarProjection';
import { mamaUserId, papaUserId } from '../../lib/familyRoles';

export function WeekView() {
  const { household, members, me, partner } = useHousehold();
  const [weekStart, setWeekStart] = useState(() => mondayOf(new Date()));
  const days = useMemo(
    () => Array.from({ length: 7 }, (_, i) => addDays(weekStart, i)),
    [weekStart],
  );
  const { loading, error, tasks, occurrences, refresh } = usePlanningData(
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
  const [detail, setDetail] = useState<CalendarProjectionItem | null>(null);
  const primaryUserId = papaUserId(members);
  const partnerUserId = mamaUserId(members);
  const projection = useMemo(
    () => buildCalendarProjection({ tasks, occurrences, primaryUserId, partnerUserId }),
    [occurrences, partnerUserId, primaryUserId, tasks],
  );
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
            const transport = projection.transportByDate.get(date);
            const dayItems = projection.itemsByDate.get(date) ?? [];
            return (
              <section className="week-day-card" key={date}>
                <h2>{formatShortDate(day)}</h2>
                {!transport && dayItems.length === 0 ? (
                  <p className="empty-hint">予定なし</p>
                ) : (
                  <ul>
                    {transport && (
                      <li className="transport-event">
                        <strong>{(() => { const tokens = transportTokens(transport, primaryUserId, partnerUserId); return <><span>送 </span><b className={`transport-token ${tokens.dropoff.tone}`}>{tokens.dropoff.token}</b><span> ｜ 迎 </span><b className={`transport-token ${tokens.pickup.tone}`}>{tokens.pickup.token}</b></>; })()}</strong>
                      </li>
                    )}
                    {dayItems.map((item) => {
                      const task = item.linkedTaskId ? tasks.find((candidate) => candidate.id === item.linkedTaskId) : null;
                      const hasConflict = Boolean(
                        task &&
                        canonical.schedule?.assignments.some(
                          (item) => item.task_instance_id === task.id && item.has_conflict,
                        ),
                      );
                      return (
                        <li
                          key={item.id}
                          className={item.source === 'google' ? 'calendar-event' : 'task-event'}
                        >
                          <button type="button" className="calendar-detail-trigger" onClick={() => setDetail(item)}>
                            <span>{item.startsAt ? formatTimeJa(item.startsAt) : '終日'}</span>
                            <strong>{item.fullTitle}</strong>
                          </button>
                          {(hasConflict || item.hasConflict) && <span className="error-text">⚠ 予定と重複</span>}
                          <small className={`assignee-badge ${item.ownerKind}`}>[{assigneeToken(item.ownerKind)}]</small>
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
      {detail && <CalendarItemDetail detail={detail} onClose={() => setDetail(null)} />}
    </main>
  );
}

function CalendarItemDetail({ detail, onClose }: { detail: CalendarProjectionItem; onClose: () => void }) {
  const source = detail.source === 'google' ? 'Google Calendar' : 'Family Ops';
  return (
    <section className="card calendar-detail" aria-label="予定の詳細">
      <div className="section-heading"><h2>予定の詳細</h2><button type="button" className="text-button" onClick={onClose}>閉じる</button></div>
      <strong>{detail.fullTitle}</strong>
      <p>開始: {detail.allDay ? `${detail.localDate}（終日）` : detail.startsAt ?? '—'}</p>
      <p>終了: {detail.allDay ? `${detail.localDate}（終日）` : detail.endsAt ?? '—'}</p>
      {detail.location && <p>場所: {detail.location}</p>}
      {detail.description && <p>説明: {detail.description}</p>}
      <p>出所: {source}{detail.sourceCalendar ? ` · ${detail.sourceCalendar}` : ''}</p>
    </section>
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
  const [alreadyAgreed, setAlreadyAgreed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [previewing, setPreviewing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      if (alreadyAgreed) {
        await callEdgeFunction(EDGE_FUNCTIONS.changeTaskAssignment, {
          operation_id: newOperationId(), task_id: task.id, assignee_user_id: partnerId,
          already_agreed: true, expected_revision: task.revision ?? 1,
        });
      } else {
        await callEdgeFunction(EDGE_FUNCTIONS.createAssignmentChangeRequest, {
          operation_id: newOperationId(), task_id: task.id, recipient_user_id: partnerId,
          scope, shared_message: message,
        });
      }
      await onSaved();
    } catch (err) {
      setError(
        err instanceof FamilyOpsApiError ? err.message : '担当変更のお願いを送れませんでした。',
      );
    } finally {
      setBusy(false);
    }
  };
  const scopeLabel = alreadyAgreed ? '今回だけ' : scope === 'this_week' ? '今週だけ' : '今回だけ';
  return (
    <div className="modal-backdrop" role="presentation">
      <form className="modal-panel stack-form" onSubmit={submit}>
        <div className="modal-header">
          <h2>{task.title}の担当を相談</h2>
          <button type="button" className="modal-close" onClick={onClose}>
            ×
          </button>
        </div>
        <p>{alreadyAgreed ? '口頭などで調整済みとして、通知付きで担当を更新します。' : '相手が「やる」を押すまで、担当は変わりません。'}</p>
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
                disabled={alreadyAgreed}
              >
                <option value="once">今回だけ</option>
                <option value="this_week">今週だけ</option>
              </select>
            </label>
            <label className="checkbox-row">
              <input type="checkbox" checked={alreadyAgreed} onChange={(event) => setAlreadyAgreed(event.target.checked)} />
              口頭などで、すでに二人で調整済み
            </label>
            {alreadyAgreed && <p className="task-item-meta">調整済みは今回だけに反映します。新しい承認依頼は作りません。</p>}
            {!alreadyAgreed && <label>
              {alreadyAgreed ? '相手へ残すひとこと（任意）' : `${partnerName}へ送る文面`}
              <textarea
                value={message}
                onChange={(event) => setMessage(event.target.value)}
                placeholder="今日ちょっと遅くなるので、お願いできる？"
              />
            </label>}
            <button type="button" disabled={busy} onClick={() => setPreviewing(true)}>
              {alreadyAgreed ? '変更内容を確認' : 'LINE送信内容を確認'}
            </button>
          </>
        ) : (
          <section className="line-sender-preview" aria-label="LINE担当変更プレビュー">
            <p className="line-preview-kicker">LINE · 送る側の確認</p>
            <h3>{alreadyAgreed ? 'この内容で担当を更新しますか？' : 'この内容で送りますか？'}</h3>
            <p className="line-preview-message">{alreadyAgreed ? '二人で調整済みの内容を、今回だけ反映します。' : message || '担当をお願いしてもいい？'}</p>
            <p className="line-preview-meta">
              {task.title} / {scopeLabel} / 自分 → {partnerName}
            </p>
            <p className="empty-hint">{alreadyAgreed ? '更新後、相手には「担当を更新しました」と通知されます。' : '送るまでは相手に通知されません。'}</p>
            <div className="modal-actions">
              <button
                type="button"
                className="secondary-button"
                disabled={busy}
                onClick={() => setPreviewing(false)}
              >
                編集
              </button>
              <button disabled={busy}>{busy ? '処理中…' : alreadyAgreed ? '調整済みで更新' : 'LINEで送る'}</button>
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
