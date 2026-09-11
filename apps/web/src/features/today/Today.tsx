import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../../app/AuthContext';
import { useHousehold } from '../../app/HouseholdContext';
import {
  useTodayData,
  type DailyBriefScheduleItem,
  type TodayRequestAttempt,
} from './useTodayData';
import { usePendingActions } from './usePendingActions';
import { TodayTaskItem } from './TodayTaskItem';
import { TomorrowPreparationCard } from './TomorrowPreparationCard';
import { PendingActionCard } from './PendingActionCard';
import { PendingActionEditModal } from './PendingActionEditModal';
import { TaskFormModal } from '../tasks/TaskFormModal';
import { QuickAdd } from '../tasks/QuickAdd';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { formatDateTimeJa } from '../../lib/date';
import { formatTokyoHeading } from './todayClock';
import { useTodayClock } from './useTodayClock';
import type { PendingAction, RequestRow, TaskInstance } from '../../lib/types';

const INPUT_LABELS: Record<string, string> = {
  dropoff: '朝の入力',
  pickup: 'お迎えの入力',
  nonpickup_evening: '今夜の入力',
};

const REQUEST_STATE_LABELS: Record<TodayRequestAttempt['state'], string> = {
  pending: '返事待ち',
  checking: '確認中',
  consulting: '相談中',
  awaiting_confirmation: '合意確認待ち',
  accepted: '引き受け済み',
  declined: '見送り済み',
  expired: '返事期限切れ',
  cancelled: '取り消し済み',
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

function RequestQuickActions({
  request,
  attempt,
  onChanged,
}: {
  request: RequestRow;
  attempt?: TodayRequestAttempt;
  onChanged: () => void | Promise<void>;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showOther, setShowOther] = useState(false);
  const actionable = isTodayRequestAttemptActionable(attempt);

  async function respond(kind: 'accept' | 'decline' | 'checking' | 'consult') {
    if (!attempt || !isTodayRequestAttemptActionable(attempt)) {
      setError('このお願いは最新状態を確認してから返事してください。');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const functionName = kind === 'checking' || kind === 'consult'
        ? EDGE_FUNCTIONS.respondRequest
        : kind === 'accept' && request.assignment_task_instance_id
          ? EDGE_FUNCTIONS.acceptAssignmentChangeRequest
          : kind === 'accept'
            ? EDGE_FUNCTIONS.acceptRequest
            : EDGE_FUNCTIONS.declineRequest;
      const result = await callEdgeFunction<{ reproposal_required?: boolean }>(functionName, {
        operation_id: newOperationId(),
        ...todayRequestTransitionPayload(request.id, attempt),
        ...(kind === 'checking' || kind === 'consult' ? { response_action: kind } : {}),
      });
      if (result.reproposal_required) {
        setError('返事期限を過ぎています。お願い画面から新しい条件で提案してください。');
      }
      await onChanged();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。最新状態を読み直してください。');
    } finally {
      setBusy(false);
    }
  }

  return (
    <li className="request-item">
      <div>
        <strong>{request.shared_title}</strong>
        {request.shared_message && <p>{request.shared_message}</p>}
        {attempt && (
          <span className="task-item-meta">返事状態: {REQUEST_STATE_LABELS[attempt.state]}</span>
        )}
        {attempt?.reply_due_at && (
          <span className="task-item-meta">返事期限: {formatDateTimeJa(attempt.reply_due_at)}</span>
        )}
        {request.due_at && (
          <span className="task-item-meta">作業期限: {formatDateTimeJa(request.due_at)}</span>
        )}
      </div>
      {actionable && (
        <div className="task-item-actions">
          <button type="button" disabled={busy} onClick={() => respond('accept')}>やる</button>
          <button type="button" disabled={busy} onClick={() => respond('decline')}>難しい</button>
          <button type="button" className="text-button" disabled={busy} onClick={() => setShowOther((value) => !value)}>
            その他の返答
          </button>
        </div>
      )}
      {actionable && showOther && attempt && (
        <div className="request-other-actions">
          {attempt.state === 'pending' && (
            <button type="button" className="secondary-button" disabled={busy} onClick={() => respond('checking')}>
              確認してみる
            </button>
          )}
          <button type="button" className="secondary-button" disabled={busy} onClick={() => respond('consult')}>
            相談する
          </button>
          <p className="task-item-meta">相談では、今の条件を二人で確認してから合意します。担当はこの時点では変わりません。</p>
        </div>
      )}
      {!attempt && <p className="task-item-meta">最新の返事状態を確認中です。</p>}
      {attempt && !actionable && ['consulting', 'awaiting_confirmation'].includes(attempt.state) && (
        <p className="task-item-meta">相談中です。お願い画面で条件を確認してください。</p>
      )}
      {attempt && !actionable && !['consulting', 'awaiting_confirmation'].includes(attempt.state) && (
        <p className="task-item-meta">このお願いはここから返事できません。お願い画面で最新状態を確認してください。</p>
      )}
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
  const { user } = useAuth();
  const { household, members, partner } = useHousehold();
  const data = useTodayData(household?.id ?? null, user?.id ?? null);
  const pending = usePendingActions(household?.id ?? null, user?.id ?? null);
  const clock = useTodayClock(data.refresh);
  const navigate = useNavigate();
  const [editingTask, setEditingTask] = useState<TaskInstance | null>(null);
  const [correctionTitle, setCorrectionTitle] = useState<string | null>(null);
  const [editingPendingAction, setEditingPendingAction] = useState<PendingAction | null>(null);
  const [shoppingCollapsed, setShoppingCollapsed] = useState(true);

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

  const phaseTasks = clock.daypart === 'morning'
    ? data.taskGroups.morning
    : clock.daypart === 'day'
      ? data.taskGroups.daytime
      : data.taskGroups.evening;
  const nextTask = phaseTasks[0] ?? data.tasks[0] ?? null;
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
  const tomorrowDate = data.tomorrowImpact.local_date ?? clock.localDate;
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

  function jumpToSection(targetId: string, fallbackPath: string) {
    const target = document.getElementById(targetId);
    if (target) {
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
      return;
    }
    navigate(fallbackPath);
  }

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
            onEdit={setEditingTask}
            onChanged={data.refresh}
          />
        ))}
      </ul>
    );
  }

  function renderTaskSection(title: string, tasks: TaskInstance[], eyebrow?: string) {
    if (tasks.length === 0) return null;
    return (
      <section className="card task-section">
        <div className="section-heading">
          <div>
            {eyebrow && <p className="eyebrow">{eyebrow}</p>}
            <h2>{title}</h2>
          </div>
          <span>{tasks.length}件</span>
        </div>
        {renderTaskList(tasks)}
      </section>
    );
  }

  function renderDecisions() {
    if (!hasPendingDecisions) return null;
    return (
      <section id="today-attention" className="card decision-card" aria-label="まず確認">
        <div className="section-heading">
          <div><p className="eyebrow">まず確認</p><h2>先に決めること</h2></div>
          <span>{data.urgentActions.length + pending.pendingActions.length}件</span>
        </div>
        <ul className="request-list">
          {data.incomingRequests.map((request) => (
            <RequestQuickActions
              key={request.id}
              request={request}
              attempt={data.requestAttemptsByRequestId.get(request.id)}
              onChanged={data.refresh}
            />
          ))}
          {nonRequestUrgent.map((action, index) => (
            <li className="request-item" key={`${action.kind ?? 'urgent'}:${action.task_id ?? index}`}>
              <strong>{action.title ?? '確認が必要です'}</strong>
              {action.kind === 'assignment_needed' && <p className="task-item-meta">担当がまだ決まっていません。</p>}
              {action.kind === 'waiting_risk' && <p className="task-item-meta">待ち状態ですが、期限への影響を確認してください。</p>}
            </li>
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
          <div><p className="eyebrow">いつもと違うこと</p><h2>今日の例外</h2></div>
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
          <div><p className="eyebrow">待ち・確認</p><h2>確認すること</h2></div>
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
          <div><p className="eyebrow">今 / 次</p><h2>今日の予定</h2></div>
          <span>{data.briefSchedule.length}件</span>
        </div>
        <ul className="today-schedule-list">
          {data.briefSchedule.map((item) => (
            <li key={item.family_event_id ?? item.occurrence_key ?? `${item.kind}:${item.starts_at}:${item.title}`}>
              {scheduleLabel(item)}
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
        <div className="section-heading"><div><p className="eyebrow">引き継ぎ・共有</p><h2>未読の引き継ぎ</h2></div></div>
        <ul className="handover-list">
          {data.unreadHandovers.map((handover) => (
            <li key={handover.id} className="handover-item unread"><strong>{handover.period}</strong> — {handover.shared_text}</li>
          ))}
        </ul>
      </section>
    );
  }

  function renderPartnerState() {
    const items = data.partnerSummary.critical_items ?? [];
    const open = data.partnerSummary.open_assigned ?? 0;
    const completed = data.partnerSummary.completed_today ?? 0;
    if (items.length === 0 && open === 0 && completed === 0) return null;
    return (
      <section className="card compact-section partner-summary" aria-label="相手の今日">
        <p className="eyebrow">相手の今日</p>
        <h2>残り {open}件・完了 {completed}件</h2>
        {items.length > 0 && (
          <>
            <p className="task-item-meta">重要な項目</p>
            <ul className="today-schedule-list">
              {items.slice(0, 3).map((item) => <li key={item.task_id}>{item.title}</li>)}
            </ul>
          </>
        )}
      </section>
    );
  }

  function renderTomorrowImpact() {
    if (data.tomorrowImpact.impact_count === 0) return null;
    return (
      <section id="today-tomorrow" className="card compact-section" aria-label="明日に影響">
        <div className="section-heading">
          <div><p className="eyebrow">明日に影響</p><h2>明日の見通し</h2></div>
          <span>{data.tomorrowImpact.impact_count}件</span>
        </div>
        <ul className="today-schedule-list">
          {tomorrowTasks.slice(0, 3).map((task) => <li key={task.task_id}>{task.title ?? 'タスク'}</li>)}
          {data.tomorrowImpact.schedule.slice(0, Math.max(0, 3 - tomorrowTasks.length)).map((item) => (
            <li key={item.family_event_id ?? item.occurrence_key ?? `${item.kind}:${item.starts_at}`}>{scheduleLabel(item)}</li>
          ))}
        </ul>
        <button type="button" className="text-button" onClick={() => navigate('/week')}>週の予定を開く</button>
      </section>
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

  async function handleEditAsRequest(action: PendingAction) {
    navigate('/requests', {
      state: { pendingActionRawText: String(action.normalized_payload.raw_text ?? '') },
    });
  }

  async function handleEditAsTask(action: PendingAction) {
    setCorrectionTitle(String(action.normalized_payload.raw_text ?? ''));
  }

  if (data.loading) {
    return <div className="app-shell"><p role="status">読み込み中…</p></div>;
  }

  const morningResidual = data.taskGroups.morning;
  const daytimeResidual = data.taskGroups.daytime;
  const eveningTasks = data.taskGroups.evening;
  const optionalTasks = data.taskGroups.optional;
  const unfinishedBeforeEvening = [...morningResidual, ...daytimeResidual];
  const remainingCount = new Set(
    [...data.carryoverTasks, ...morningResidual, ...daytimeResidual, ...eveningTasks].map((task) => task.id),
  ).size;
  const attentionCount = data.urgentActions.length + pending.pendingActions.length;

  return (
    <div className="app-shell">
      <div className="today-header today-page-heading">
        <div>
          <p className="eyebrow">{formatTokyoHeading(clock.now)} · 今日の段取り</p>
          <h1>今日</h1>
        </div>
        <QuickAdd label="＋ 追加" ariaLabel="追加する" onTaskSaved={data.refresh} />
      </div>

      {data.status === 'stale' && (
        <p role="status" className="empty-hint">通信が不安定なため、最後に取得できた内容を表示しています。</p>
      )}
      {data.error && <p role="alert" className="error-text">{data.error}</p>}
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

      <section
        className="today-contract-shortcuts"
        aria-label="今日の重要サマリー"
        style={{ display: 'grid', gridTemplateColumns: 'repeat(2, minmax(0, 1fr))', gap: '0.5rem', marginBottom: '1rem' }}
      >
        <button
          type="button"
          className="secondary-button"
          aria-label={`要対応 ${attentionCount}件を確認`}
          style={{ display: 'grid', gap: '0.15rem', textAlign: 'left', padding: '0.7rem' }}
          onClick={() => jumpToSection('today-attention', '/requests')}
        >
          <small>返事・担当・確認</small><strong>要対応 {attentionCount}</strong>
        </button>
        <button
          type="button"
          className="secondary-button"
          aria-label={`残り ${remainingCount}件を確認`}
          style={{ display: 'grid', gap: '0.15rem', textAlign: 'left', padding: '0.7rem' }}
          onClick={() => jumpToSection('today-remaining', '/week')}
        >
          <small>今日の自分の残件</small><strong>残り {remainingCount}</strong>
        </button>
        <button
          type="button"
          className="secondary-button"
          aria-label={`待ち ${data.waitingTasks.length}件を確認`}
          style={{ display: 'grid', gap: '0.15rem', textAlign: 'left', padding: '0.7rem' }}
          onClick={() => jumpToSection('today-waiting', '/week')}
        >
          <small>確認日・期限リスク</small><strong>待ち {data.waitingTasks.length}</strong>
        </button>
        <button
          type="button"
          className="secondary-button"
          aria-label={`明日影響 ${data.tomorrowImpact.impact_count}件を確認`}
          style={{ display: 'grid', gap: '0.15rem', textAlign: 'left', padding: '0.7rem' }}
          onClick={() => jumpToSection('today-tomorrow', '/week')}
        >
          <small>明日の予定・準備</small><strong>明日影響 {data.tomorrowImpact.impact_count}</strong>
        </button>
      </section>

      {clock.daypart === 'morning' && (
        <>
          {renderDecisions()}
          {renderExceptions()}
          {renderTaskSection('昨夜からの持ち越し', data.carryoverTasks, 'いつもと違うこと')}
          {renderHandovers()}
          {data.alreadyHandledTasks.length > 0 && renderTaskSection('対応済み', data.alreadyHandledTasks, '二重対応を防ぐ')}
          {renderWaiting()}
          <div id="today-remaining" aria-hidden="true" />
          {renderInput()}
          {renderTaskSection('朝やること', morningResidual, '今日やること')}
          {renderTaskSection('このあと', [...daytimeResidual, ...eveningTasks], '先の見通し')}
          {renderPartnerState()}
          {renderSchedule()}
        </>
      )}

      {clock.daypart === 'day' && (
        <>
          {renderDecisions()}
          {renderExceptions()}
          {renderTaskSection('持ち越し', data.carryoverTasks, 'いつもと違うこと')}
          {renderHandovers()}
          {data.alreadyHandledTasks.length > 0 && renderTaskSection('対応済み', data.alreadyHandledTasks, '二重対応を防ぐ')}
          {renderWaiting()}
          {renderSchedule()}
          <div id="today-remaining" aria-hidden="true" />
          {nextTask && (
            <section className="next-action-hero" aria-labelledby="next-action-title">
              <span className="next-action-pill">次にやること</span>
              <p className="next-action-time">
                {nextTask.due_at
                  ? new Intl.DateTimeFormat('ja-JP', { timeZone: 'Asia/Tokyo', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(nextTask.due_at))
                  : '今日中'}
              </p>
              <h2 id="next-action-title">{nextTask.title}</h2>
              <p>今日のDailyBriefで、いま優先する担当項目です。</p>
              <div className="next-action-actions">
                <button type="button" className="hero-primary" onClick={() => setEditingTask(nextTask)}>開く →</button>
                <button type="button" className="hero-secondary" onClick={() => navigate('/week')}>今回だけ変更</button>
              </div>
            </section>
          )}
          {renderInput()}
          {renderTaskSection('朝の残り', morningResidual, 'まだ終わっていないこと')}
          {renderTaskSection('今やること', daytimeResidual, '今日やること')}
          {renderTaskSection('このあと', eveningTasks, '先の見通し')}
          {renderPartnerState()}
        </>
      )}

      {clock.daypart === 'evening' && (
        <>
          {renderDecisions()}
          {renderExceptions()}
          {renderHandovers()}
          {data.morningSummary.totalCount > 0 && (
            <section className="card compact-section" aria-label="朝の完了まとめ">
              <p className="eyebrow">もう済んでいること</p>
              <h2>朝 {data.morningSummary.completedCount}/{data.morningSummary.totalCount} 完了</h2>
            </section>
          )}
          {renderWaiting()}
          {renderSchedule()}
          <div id="today-remaining" aria-hidden="true" />
          {renderTaskSection('まだ残っていること', [...data.carryoverTasks, ...unfinishedBeforeEvening], '今日をしめくくる')}
          {renderTaskSection('夜にやること', eveningTasks, '今日やること')}
          {renderTomorrowImpact()}
          {renderInput()}
          {renderPartnerState()}
          {renderShopping()}
          {data.reconciliation.remaining_count > 0 && !currentInput && (
            <section className="card compact-section" aria-label="まとめ入力">
              <p className="eyebrow">まとめ入力</p>
              <h2>未確認 {data.reconciliation.remaining_count}件</h2>
              <p className="empty-hint">担当者の入力待ちです。</p>
            </section>
          )}
        </>
      )}

      {optionalTasks.length > 0 && renderTaskSection('余裕があれば', optionalTasks)}

      {clock.daypart !== 'evening' && renderTomorrowImpact()}
      {clock.daypart !== 'evening' && renderShopping()}

      {tomorrowDate && (
        <TomorrowPreparationCard
          tomorrowDate={tomorrowDate}
          assigneeId={tomorrowAssigneeId}
          assigneeLabel={tomorrowAssigneeLabel}
          existingTitles={tomorrowPreparationTitles}
          onChanged={() => void data.refresh()}
        />
      )}

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
            void data.refresh();
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
            void data.refresh();
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
  );
}
