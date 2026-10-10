import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { useAuth } from '../../app/AuthContext';
import { useHousehold } from '../../app/HouseholdContext';
import {
  useTodayData,
  type DailyBriefScheduleItem,
  type TodayRequestAttempt,
} from './useTodayData';
import { IncomingRequestRow } from '../requests/Requests';
import { usePendingActions } from './usePendingActions';
import { TodayTaskItem } from './TodayTaskItem';
import { TaskSelectionProvider } from '../tasks/TaskSelection';
import { TomorrowPreparationCard } from './TomorrowPreparationCard';
import { PendingActionCard } from './PendingActionCard';
import { PendingActionEditModal } from './PendingActionEditModal';
import { PERIOD_LABELS } from '../handovers/Handovers';
import { TaskFormModal } from '../tasks/TaskFormModal';
import { FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { useCommandAttempt } from '../../lib/useCommandAttempt';
import { useTodayClock } from './useTodayClock';
import type { PendingAction, RequestRow, TaskInstance } from '../../lib/types';
import { buildCodmonCompletionPrerequisite } from './codmonReadiness';
import { LoadingScreen } from '../../components/LoadingScreen';
import { HandoverActions } from '../handovers/HandoverActions';
import { DayAgendaSheet } from '../planning/DayAgendaSheet';
import { tokyoIsoDate } from '../planning/dateHelpers';
import { useDayTaskRecording } from './useDayTaskRecording';
import { TaskRecordingBadge } from '../tasks/TaskRecordingBadge';

const INPUT_LABELS: Record<string, string> = {
  dropoff: '朝の入力',
  pickup: 'お迎えの入力',
  nonpickup_evening: '今夜の入力',
};


export function selectNextOwnedTask(tasks: TaskInstance[], userId: string | null | undefined) {
  if (!userId) return null;
  return (
    tasks
      .filter(
        (task) =>
          task.planned_assignee_id === userId &&
          (task.status === 'todo' || task.status === 'in_progress'),
      )
      .sort((a, b) => (a.due_at ?? '9999').localeCompare(b.due_at ?? '9999'))[0] ?? null
  );
}

export function shouldShowWaitingTask(task: TaskInstance, now = new Date()): boolean {
  if (task.attention_state !== 'waiting' || !['todo', 'in_progress'].includes(task.status)) return false;
  if (!task.next_check_at) return true;
  if (new Date(task.next_check_at) <= now) return true;
  return Boolean(task.due_at && new Date(task.due_at) <= now);
}

export function isTodayRequestAttemptActionable(
  attempt: TodayRequestAttempt | undefined,
  nowMs = Date.now(),
): boolean {
  if (!attempt || !['pending', 'checking'].includes(attempt.state)) return false;
  return !attempt.reply_due_at || new Date(attempt.reply_due_at).getTime() > nowMs;
}

export function todayRequestTransitionPayload(requestId: string, attempt: TodayRequestAttempt) {
  return {
    request_id: requestId,
    attempt_id: attempt.id,
    expected_revision: attempt.revision,
    expected_terms_revision: attempt.terms_revision,
  };
}

function RequestQuickActions({ request, attempt, onChanged }: { request: RequestRow; attempt?: TodayRequestAttempt; onChanged: () => void | Promise<void> }) {
  return <IncomingRequestRow request={request} attempt={attempt ? { ...attempt, terms: attempt.terms ?? null } : undefined} onChanged={onChanged} />;
}

function AssignmentNeededQuickAction({
  title,
  task,
  userId,
  partnerId,
  onChanged,
}: {
  title: string;
  task?: TaskInstance;
  userId: string | null | undefined;
  partnerId: string | null | undefined;
  onChanged: () => void | Promise<void>;
}) {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const runCommand = useCommandAttempt();

  async function run(action: 'self' | 'partner') {
    if (!task || !userId) {
      setError('最新状態を読み直してください。');
      return;
    }
    if (action === 'partner' && !partnerId) {
      setError('お願いできる相手を確認できません。');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      if (action === 'self') {
        await runCommand(
          `task:${task.id}:resolve-assignment:self:${userId}:r${task.revision ?? 1}`,
          EDGE_FUNCTIONS.changeTaskAssignment,
          (operationId) => ({
            operation_id: operationId,
            task_id: task.id,
            assignee_user_id: userId,
            already_agreed: true,
            expected_revision: task.revision ?? 1,
          }),
        );
      } else {
        await runCommand(
          `task:${task.id}:resolve-assignment:request:${partnerId}:r${task.revision ?? 1}`,
          EDGE_FUNCTIONS.createAssignmentChangeRequest,
          (operationId) => ({
            operation_id: operationId,
            task_id: task.id,
            recipient_user_id: partnerId,
            scope: 'once',
            shared_message: 'この担当をお願いできますか？',
            expected_task_revision: task.revision ?? 1,
          }),
        );
      }
      setOpen(false);
      await onChanged();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '担当を更新できませんでした。最新状態を読み直してください。');
      await onChanged();
    } finally {
      setBusy(false);
    }
  }

  return (
    <li className="request-item">
      <strong>{title}</strong>
      <p className="task-item-meta">
        担当がまだ決まっていません。ここから担当を決められます。
      </p>
      {!open ? (
        <button type="button" className="secondary-button" disabled={busy || !task} onClick={() => setOpen(true)}>
          担当を決める
        </button>
      ) : (
        <div className="request-other-actions">
          <button type="button" disabled={busy} onClick={() => void run('self')}>自分が担当</button>
          {partnerId && (
            <button type="button" className="secondary-button" disabled={busy} onClick={() => void run('partner')}>
              相手にお願い
            </button>
          )}
          <button type="button" className="text-button" disabled={busy} onClick={() => setOpen(false)}>戻る</button>
          <p className="task-item-meta">
            「相手にお願い」は、相手が引き受けるまで担当を変更しません。
          </p>
        </div>
      )}
      {!task && <p role="alert" className="error-text">対象の最新状態を読み込み直してください。</p>}
      {error && <p role="alert" className="error-text">{error}</p>}
    </li>
  );
}

function scheduleLabel(item: DailyBriefScheduleItem): string {
  if (item.is_all_day) return `終日 ${item.title ?? '名称未設定'}`;
  if (!item.starts_at) return item.title ?? '名称未設定';
  const time = new Intl.DateTimeFormat('ja-JP', {
    timeZone: 'Asia/Tokyo',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(new Date(item.starts_at));
  return `${time} ${item.title ?? '名称未設定'}`;
}

export function Today() {
  const [params, setParams] = useSearchParams();
  const { household, me } = useHousehold();
  const currentClock = useTodayClock(() => {});
  const today = tokyoIsoDate(currentClock.now);
  const value = params.get('date') ?? today;
  const parsed = new Date(`${value}T00:00:00Z`);
  const date = /^\d{4}-\d{2}-\d{2}$/.test(value) && !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value ? value : today;
  const recording = useDayTaskRecording(household?.id ?? null, date, me?.user_id ?? null);
  function selectDate(next: string) {
    const copy = new URLSearchParams(params);
    if (next === today) copy.delete('date'); else copy.set('date', next);
    setParams(copy);
  }
  function move(delta: number) {
    const next = new Date(`${date}T00:00:00Z`);
    next.setUTCDate(next.getUTCDate() + delta);
    selectDate(next.toISOString().slice(0, 10));
  }
  return <>
    <nav className="app-shell daily-date-nav" aria-label="実績の対象日">
      <button type="button" className="secondary-button" onClick={() => move(-1)} aria-label="前日">‹ 前日</button>
      <input aria-label="表示する日" type="date" value={date} onChange={(event) => event.target.value && selectDate(event.target.value)} />
      <button type="button" className="secondary-button" onClick={() => move(1)} aria-label="翌日">翌日 ›</button>
      <div className="daily-recording-row">
        <span role="status" aria-label="自分の記録状況" className="daily-recording-status">
          <span className="daily-recording-caption">自分の記録</span>
          {recording.summary ? <TaskRecordingBadge summary={recording.summary} future={date > today} /> : recording.error ? '取得できませんでした' : '確認中…'}
          {recording.error && <button type="button" className="text-button" onClick={() => void recording.refresh()}>再試行</button>}
        </span>
        {date !== today && <button type="button" className="text-button" onClick={() => selectDate(today)}>今日に戻る</button>}
      </div>
    </nav>
    {date === today ? <TodayDashboard onRecordingChanged={recording.refresh} /> : <div className="app-shell daily-date-content"><DayAgendaSheet key={date} date={date} inline onClose={() => selectDate(today)} onChanged={recording.refresh} /></div>}
  </>;
}

function TodayDashboard({ onRecordingChanged }: { onRecordingChanged: () => Promise<void> }) {
  const { user } = useAuth();
  const { household, members, partner } = useHousehold();
  const data = useTodayData(household?.id ?? null, user?.id ?? null);
  async function refreshToday() {
    await Promise.all([data.refresh(), onRecordingChanged()]);
  }
  const pending = usePendingActions(household?.id ?? null, user?.id ?? null);
  const clock = useTodayClock(refreshToday);
  const navigate = useNavigate();
  const [assignmentRequest, setAssignmentRequest] = useState<{ id: string; token: number } | null>(null);
  const [editingTask, setEditingTask] = useState<TaskInstance | null>(null);
  const [correctionTitle, setCorrectionTitle] = useState<string | null>(null);
  const [editingPendingAction, setEditingPendingAction] = useState<PendingAction | null>(null);
  const [shoppingCollapsed, setShoppingCollapsed] = useState(true);
  const [completedCollapsed, setCompletedCollapsed] = useState(true);

  const reconciliationSessions = data.reconciliation.sessions as Array<{
    id?: string;
    session_id?: string;
    session_type?: string;
    status?: string;
    assignee_id?: string;
    can_act?: boolean;
    remaining_count?: number;
  }>;
  const preferredInputType = clock.daypart === 'morning'
    ? 'dropoff'
    : clock.daypart === 'day'
      ? 'pickup'
      : 'nonpickup_evening';
  const currentInput = reconciliationSessions.find(
    (session) => session.can_act && session.session_type === preferredInputType,
  ) ?? reconciliationSessions.find((session) => session.can_act) ?? null;
  const currentInputId = currentInput?.id ?? currentInput?.session_id ?? null;
  const [entryParams] = useSearchParams();
  useEffect(() => {
    if (entryParams.get('entry') === 'checkin' && currentInputId) navigate(`/checkin/${currentInputId}`, { replace: true });
  }, [entryParams, currentInputId, navigate]);

  const phaseTasks = clock.daypart === 'morning'
    ? data.taskGroups.morning
    : clock.daypart === 'day'
      ? data.taskGroups.daytime
      : data.taskGroups.evening;
  const nextTask = phaseTasks.find(task => !task.due_at || new Date(task.due_at).getTime() >= clock.now.getTime()) ?? null;
  const nonRequestUrgent = data.urgentActions.filter((item) => !item.request_id);
  const hasPendingDecisions = data.urgentActions.length > 0 || pending.pendingActions.length > 0;

  const tomorrowTasks = data.tomorrowImpact.tasks as Array<{
    task_id: string;
    title?: string | null;
    task_kind?: string;
    category?: string;
    planned_assignee_id?: string | null;
    due_at?: string | null;
  }>;
  const tomorrowDate = data.tomorrowImpact.local_date ?? tokyoIsoDate(new Date(clock.now.getTime() + 86400000));
  const tomorrowDropoff = tomorrowTasks.find(
    (task) => task.task_kind === 'transport' && task.category === 'dropoff',
  );
  const tomorrowAssigneeId = tomorrowDropoff?.planned_assignee_id ?? null;
  const tomorrowAssigneeLabel = useMemo(() => {
    if (!tomorrowAssigneeId) return '';
    const member = members.find((candidate) => candidate.user_id === tomorrowAssigneeId);
    if (member?.family_role === 'papa') return 'パパ';
    if (member?.family_role === 'mama') return 'ママ';
    return member?.profile?.display_name ?? '担当あり';
  }, [members, tomorrowAssigneeId]);
  const tomorrowPreparationTitles = tomorrowTasks
    .filter((task) => task.category === 'handover_preparation')
    .map((task) => task.title)
    .filter((title): title is string => Boolean(title));


  function renderTaskList(tasks: TaskInstance[]) {
    return (
      <ul className="task-list">
        {tasks.map((task) => (
          <TodayTaskItem
            key={task.id}
            task={task}
            subtasks={data.subtasksByTaskId.get(task.id) ?? []}
            members={members}
            hasPartner={Boolean(partner)}
            currentUserId={user?.id}
            specialToday={data.specialTaskIds?.includes(task.id)}
            assignmentRequest={assignmentRequest?.id === task.id ? assignmentRequest.token : 0}
            compact
            onEdit={setEditingTask}
            onChanged={refreshToday}
            completionPrerequisite={
              data.codmon?.submit_task_id === task.id
                ? buildCodmonCompletionPrerequisite(data.codmon, members)
                : null
            }
          />
        ))}
      </ul>
    );
  }

  function renderTaskSection(title: string, tasks: TaskInstance[], eyebrow?: string) {
    if (tasks.length === 0) return null;
    return (
      <section className="card task-section" data-current={eyebrow === 'いま' || undefined}>
        <div className="section-heading">
          <div>

            <h2>{title}</h2>
          </div>
          <span>{tasks.length}件</span>
        </div>
        {renderTaskList(tasks)}
      </section>
    );
  }

  function renderPastWork(title: string, tasks: TaskInstance[]) {
    if (tasks.length === 0) return null;
    return <details className="today-past-work" aria-label={title}>
      <summary><span>{title} {tasks.length}件（記録する）
        <small>{tasks.map(task => task.title).join('、')}</small>
      </span></summary>
      {renderTaskList(tasks)}
    </details>;
  }

  function renderDecisions() {
    if (!hasPendingDecisions) return null;
    return (
      <section id="today-attention" className="card decision-card" aria-label="まず確認">
        <div className="section-heading">
          <div><h2>先に決めること</h2></div>
          <span>{data.urgentActions.length + pending.pendingActions.length}件</span>
        </div>
        <ul className="request-list">
          {data.incomingRequests.map((request) => (
            <RequestQuickActions
              key={request.id}
              request={request}
              attempt={data.requestAttemptsByRequestId.get(request.id)}
              onChanged={refreshToday}
            />
          ))}
          {nonRequestUrgent.map((action, index) => (
            action.kind === 'assignment_needed' && action.task_id ? (
              <AssignmentNeededQuickAction
                key={`assignment_needed:${action.task_id}`}
                title={action.title ?? '担当を決める項目'}
                task={data.urgentTasksById.get(action.task_id)}
                userId={user?.id}
                partnerId={partner?.user_id}
                onChanged={refreshToday}
              />
            ) : (
              <li className="request-item" key={`${action.kind ?? 'urgent'}:${action.task_id ?? index}`}>
                <strong>{action.title ?? '確認が必要です'}</strong>
                {action.kind === 'waiting_risk' && <p className="task-item-meta">待ち状態ですが、期限への影響を確認してください。</p>}
              </li>
            )
          ))}
          {pending.pendingActions.map((action) => (
            <PendingActionCard
              key={action.id}
              action={action}
              onConfirm={pending.confirm}
              onCancel={pending.cancel}
              onEdit={setEditingPendingAction}
              onEditAsRequest={handleEditAsRequest}
              onEditAsTask={handleEditAsTask}
            />
          ))}
        </ul>
      </section>
    );
  }

  function renderExceptions() {
    if (data.exceptions.length === 0) return null;
    return (
      <section className="card compact-section" aria-label="いつもと違う">
        <div className="section-heading">
          <div><h2>今日の例外</h2></div>
          <span>{data.exceptions.length}件</span>
        </div>
        <ul className="today-schedule-list">
          {data.exceptions.map((item, index) => (
            <li key={`${item.kind ?? 'exception'}:${item.task_id ?? item.event_id ?? index}`}>
              <strong>{item.title ?? '予定と違うことがあります'}</strong>
              {(item.message || item.detail) && <p className="task-item-meta">{item.message ?? item.detail}</p>}
            </li>
          ))}
        </ul>
      </section>
    );
  }

  function renderWaiting() {
    if (data.waitingTasks.length === 0) return null;
    return (
      <section id="today-waiting" className="card compact-section waiting-summary" aria-label="待ち・確認">
        <div className="section-heading">
          <div><h2>確認すること</h2></div>
          <span>{data.waitingTasks.length}件</span>
        </div>
        {renderTaskList(data.waitingTasks)}
      </section>
    );
  }

  function renderSchedule() {
    if (data.briefSchedule.length === 0) return null;
    return (
      <section className="card" aria-label="今日の予定">
        <div className="section-heading">
          <div><h2>今日の予定</h2></div>
          <span>{data.briefSchedule.length}件</span>
        </div>
        <ul className="today-schedule-list">
          {data.briefSchedule.map((item) => (
            <li key={item.family_event_id ?? item.occurrence_key ?? `${item.kind}:${item.starts_at}:${item.title}`}>
              {item.family_event_id ? <Link to={`/events/${item.family_event_id}`} aria-label={`${item.title}の予定と準備を見る`}>{scheduleLabel(item)}</Link> : scheduleLabel(item)}
            </li>
          ))}
        </ul>
      </section>
    );
  }

  function renderInput() {
    if (!currentInput || !currentInputId) return null;
    const label = INPUT_LABELS[currentInput.session_type ?? ''] ?? '今日の入力';
    return (
      <section className="card current-input-card" aria-label={label}>
        <div>
          <p className="eyebrow">{clock.daypart === 'evening' ? '今日をしめくくる' : 'いま済ませる'}</p>
          <h2>{label}</h2>
          <p>{(currentInput.remaining_count ?? 0) > 0 ? `残り ${currentInput.remaining_count}件。例外だけ詳しく入力できます。` : '入力する項目はありません。'}</p>
        </div>
        <button type="button" className="hero-primary" onClick={() => navigate(`/checkin/${currentInputId}`)}>
          入力する
        </button>
      </section>
    );
  }

  function renderHandovers() {
    if (data.unreadHandovers.length === 0) return null;
    return (
      <section className="card compact-section" aria-label="引き継ぎ・共有">
        <div className="section-heading"><div><h2>{data.unreadHandovers.every((handover) => handover.author_id === user?.id) ? 'あなたが共有中' : '未読の引き継ぎ'}</h2></div></div>
        <ul className="handover-list">
          {data.unreadHandovers.map((handover) => (
            <li key={handover.id} className="handover-item unread">
              <p><strong>{PERIOD_LABELS[handover.period] ?? 'その他'}</strong> — {handover.shared_text}</p>
              <HandoverActions handover={handover} currentUserId={user?.id} isRead={false} onChanged={refreshToday} />
            </li>
          ))}
        </ul>
      </section>
    );
  }

  // This card used to headline `残り {open}件・完了 {completed}件` at <h2> size --
  // the largest text on the screen. On a real household morning it read
  // "残り 11件・完了 0件": a scoreboard of how little the other parent had done
  // yet, at 10am. Requirements §3 forbids 勝率/ポイント/ランキング and design 04
  // §5 and §16.2 say a partner's ordinary completions belong in detail/history
  // and must not be pushed as scorekeeping, so `完了` is dropped here entirely:
  // it changes nothing the reader does, and the one case where a partner's
  // completion genuinely reduces the reader's own work is already carried by
  // the separate `もう済んでいること` section.
  //
  // The "summary counts" 04 §5 asks for are kept, demoted to a quiet meta line.
  // What leads instead is `critical_items` -- お迎え / 夕食対応 / お風呂 -- which is
  // the part §5 describes as "tasks that alter user's behavior".
  function renderPartnerState() {
    const items = data.partnerSummary.critical_items ?? [];
    const open = data.partnerSummary.open_assigned ?? 0;
    if (items.length === 0 && open === 0) return null;
    return (
      <section className="card compact-section partner-summary" aria-label="相手の今日">
        <p className="eyebrow">相手の今日</p>
        {items.length > 0 ? (
          <ul className="today-schedule-list">
            {items.slice(0, 3).map((item) => <li key={item.task_id}>{item.title}</li>)}
          </ul>
        ) : (
          <p className="task-item-meta">こちらに関係する予定はありません。</p>
        )}
        {open > 0 && <p className="task-item-meta">担当している残り {open}件</p>}
      </section>
    );
  }

  function renderTomorrowImpact() {
    if (data.tomorrowImpact.impact_count === 0) return null;
    return (
      <div id="today-tomorrow" aria-label="明日の予定と担当">
        <ul className="today-schedule-list">
          {tomorrowTasks.slice(0, 3).map((task) => <li key={task.task_id}>{task.title ?? 'タスク'}</li>)}
          {data.tomorrowImpact.schedule.slice(0, Math.max(0, 3 - tomorrowTasks.length)).map((item) => (
            <li key={item.family_event_id ?? item.occurrence_key ?? `${item.kind}:${item.starts_at}`}>{scheduleLabel(item)}</li>
          ))}
        </ul>
        <button type="button" className="text-button" onClick={() => navigate(`/today?date=${tomorrowDate}`)}>明日の詳細を開く</button>
      </div>
    );
  }

  function renderShopping() {
    if (data.openShoppingItems.length === 0) return null;
    return (
      <section className="card collapsible compact-section">
        <button type="button" className="collapsible-toggle" onClick={() => setShoppingCollapsed((value) => !value)}>
          買い物（未購入 {data.openShoppingItems.length}件）{shoppingCollapsed ? '▼' : '▲'}
        </button>
        {!shoppingCollapsed && (
          <ul className="shopping-list-compact">
            {data.openShoppingItems.map((item) => <li key={item.id}>{item.title}</li>)}
          </ul>
        )}
      </section>
    );
  }

  // Done work by time of day, missed work first (owner 2026-10-10: one long list was hard to read).
  function completedGroups(tasks: TaskInstance[]): Array<{ label: string; tasks: TaskInstance[] }> {
    const missed = tasks.filter((task) => task.status === 'skipped');
    const done = tasks.filter((task) => task.status !== 'skipped');
    return [
      { label: 'できなかった', tasks: missed },
      { label: '朝', tasks: done.filter((task) => task.routine_phase === 'morning') },
      { label: '日中・いつでも', tasks: done.filter((task) => task.routine_phase !== 'morning' && task.routine_phase !== 'evening') },
      { label: '夜', tasks: done.filter((task) => task.routine_phase === 'evening') },
    ].filter((group) => group.tasks.length > 0);
  }

  function renderCompleted() {
    const completedTasks = data.completedTodayTasks ?? [];
    if (completedTasks.length === 0) return null;
    const couldNotDoCount = completedTasks.filter((task) => task.status === 'skipped' && task.outcome_reason === 'could_not_do').length;
    return (
      <section className="card collapsible compact-section" aria-label="記録済み">
        <button
          type="button"
          className="collapsible-toggle"
          onClick={() => setCompletedCollapsed((value) => !value)}
        >
          記録済み（{completedTasks.length}件{couldNotDoCount > 0 ? `・できなかった${couldNotDoCount}件` : ''}）{completedCollapsed ? '▼' : '▲'}
        </button>
        {!completedCollapsed && (
          <>
            <p className="empty-hint">✓＝完了、−＝できなかった。押し間違えは各行の「•••」から戻せます。</p>
            {completedGroups(completedTasks).map((group) => (
              <div className="completed-group" key={group.label}>
                <h3 className="completed-group-heading">{group.label}<span>{group.tasks.length}件</span></h3>
                {renderTaskList(group.tasks)}
              </div>
            ))}
          </>
        )}
      </section>
    );
  }

  async function handleEditAsRequest(action: PendingAction) {
    navigate('/requests', {
      state: { pendingActionRawText: String(action.normalized_payload.raw_text ?? '') },
    });
  }

  async function handleEditAsTask(action: PendingAction) {
    setCorrectionTitle(String(action.normalized_payload.raw_text ?? ''));
  }

  if (data.loading) {
    // Same recovery as the app-level loader: a stuck load offers 再読み込み
    // instead of leaving the family on a bare "読み込み中…" forever.
    return <LoadingScreen />;
  }

  const morningResidual = data.taskGroups.morning;
  const daytimeResidual = data.taskGroups.daytime;
  const eveningTasks = data.taskGroups.evening;
  const optionalTasks = data.taskGroups.optional;

  return (
    <TaskSelectionProvider onChanged={refreshToday} partnerLabel={partner?.family_role === 'papa' ? 'パパ' : partner?.family_role === 'mama' ? 'ママ' : undefined}>
    <div className="app-shell today-dashboard">
      <div className="today-header today-page-heading"><h1>今日</h1></div>

      {data.status === 'stale' && (
        <p role="status" className="empty-hint">通信が不安定なため、最後に取得できた内容を表示しています。</p>
      )}
      {data.error && <section className="card" role="alert"><strong>今日の情報を取得できませんでした</strong><p>{data.status === 'stale' ? '最後に取得した内容です。担当や予定が変わっている可能性があります。' : '予定なし・担当未定とは限りません。通信状態を確認してください。'}</p><button onClick={() => void refreshToday()}>もう一度読み込む</button></section>}
      {entryParams.get('entry') === 'checkin' && !currentInputId && !data.error && <section className="card" role="status"><p>今まとめて入力する項目はありません。下の作業から、終わったものを個別に記録できます。</p><button className="text-button" onClick={() => navigate('/history')}>記録を見返す</button></section>}
      {pending.error && <p role="alert" className="error-text">確認項目の取得に失敗しました: {pending.error}</p>}

      <section className="today-shortcuts" aria-label="よく使う操作">
        {currentInputId && (
          <button type="button" className="today-shortcut-primary" onClick={() => navigate(`/checkin/${currentInputId}`)}>
            <span aria-hidden="true">{currentInput?.session_type === 'nonpickup_evening' ? '🌙' : '📝'}</span> 入力
          </button>
        )}
        <button type="button" onClick={() => navigate('/requests')}><span aria-hidden="true">🙏</span> お願い</button>
        <button type="button" onClick={() => navigate('/handovers')}><span aria-hidden="true">💬</span> 共有</button>
      </section>


      {renderDecisions()}
      {renderExceptions()}
      {renderSchedule()}
      {clock.daypart === 'day' && nextTask && <section className="card next-task-compact" aria-label="次にやること"><strong>次にやること</strong><p>{nextTask.title}</p><div className="button-row"><button className="text-button" onClick={() => document.getElementById(`task-${nextTask.id}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' })}>作業を確認</button><button className="text-button" onClick={() => setAssignmentRequest({ id: nextTask.id, token: Date.now() })}>今回だけ変更</button></div></section>}
      <section className="today-own-work" aria-label="自分のやること"><h2>自分のやること</h2>
        {renderTaskSection('持ち越し', data.carryoverTasks)}
        {clock.daypart !== 'evening' && renderTaskSection(clock.daypart === 'morning' ? '朝やること' : '朝の残り', morningResidual, clock.daypart === 'morning' ? 'いま' : undefined)}
        {clock.daypart !== 'evening' && renderTaskSection('日中にやること', daytimeResidual, clock.daypart === 'day' ? 'いま' : undefined)}
        {renderTaskSection('夜にやること', eveningTasks, clock.daypart === 'evening' ? 'いま' : undefined)}
        {clock.daypart === 'evening' && renderPastWork('朝の残り', morningResidual)}
        {clock.daypart === 'evening' && renderPastWork('日中の残り', daytimeResidual)}
      </section>
      {renderInput()}
      {renderWaiting()}
      {renderHandovers()}
      {data.alreadyHandledTasks.some(task => task.actual_completed_by_id !== user?.id) && renderTaskSection('もう済んでいること', data.alreadyHandledTasks.filter(task => task.actual_completed_by_id !== user?.id))}
      {renderPartnerState()}

      {optionalTasks.length > 0 && (
        <details className="today-optional">
          <summary>
            <span>余裕があれば</span>
            <small>{optionalTasks.length}件</small>
          </summary>
          {renderTaskList(optionalTasks)}
        </details>
      )}
      {renderCompleted()}


      {!data.error && tomorrowDate && (
        <TomorrowPreparationCard
          tomorrowDate={tomorrowDate}
          assigneeId={tomorrowAssigneeId}
          assigneeLabel={tomorrowAssigneeLabel}
          existingTitles={tomorrowPreparationTitles}
          onChanged={() => void refreshToday()}
        >{renderTomorrowImpact()}</TomorrowPreparationCard>
      )}

      {renderShopping()}

      {data.status === 'empty' && !pending.loading && !pending.error && !hasPendingDecisions && (
        <section className="card compact-section" aria-label="今日の空状態">
          <h2>今日は確認が必要な項目はありません</h2>
          <p className="empty-hint">予定やタスクを追加すると、ここに表示されます。</p>
        </section>
      )}

      {editingTask && (
        <TaskFormModal
          mode="edit"
          task={editingTask}
          onClose={() => setEditingTask(null)}
          onSaved={() => {
            setEditingTask(null);
            void refreshToday();
          }}
        />
      )}
      {correctionTitle !== null && (
        <TaskFormModal
          mode="create"
          initialTitle={correctionTitle}
          onClose={() => setCorrectionTitle(null)}
          onSaved={() => {
            setCorrectionTitle(null);
            void refreshToday();
          }}
        />
      )}
      {editingPendingAction && (
        <PendingActionEditModal
          action={editingPendingAction}
          onClose={() => setEditingPendingAction(null)}
          onSave={(actionType, payload) => pending.update(editingPendingAction.id, actionType, payload)}
        />
      )}
    </div>
    </TaskSelectionProvider>
  );
}
