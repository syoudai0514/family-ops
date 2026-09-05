import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../../app/AuthContext';
import { useHousehold } from '../../app/HouseholdContext';
import { useTodayData } from './useTodayData';
import { usePendingActions } from './usePendingActions';
import { useTodaySchedule } from './useTodaySchedule';
import { TodayTaskItem } from './TodayTaskItem';
import { TodaySchedule } from './TodaySchedule';
import { TomorrowPreparationCard } from './TomorrowPreparationCard';
import { PendingActionCard } from './PendingActionCard';
import { PendingActionEditModal } from './PendingActionEditModal';
import { useCurrentRoutineSessions, type CurrentRoutineSessionType } from '../checkin/useCurrentRoutineSessions';
import { TaskFormModal } from '../tasks/TaskFormModal';
import { QuickAdd } from '../tasks/QuickAdd';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { formatDateTimeJa } from '../../lib/date';
import { addDays, tokyoIsoDate } from '../planning/dateHelpers';
import { usePlanningData } from '../planning/usePlanningData';
import {
  assigneeToken,
  buildCalendarProjection,
  transportLabel,
} from '../planning/calendarProjection';
import { mamaUserId, papaUserId } from '../../lib/familyRoles';
import type { PendingAction, RequestRow, TaskInstance } from '../../lib/types';

const INPUT_LABELS: Record<CurrentRoutineSessionType, string> = {
  dropoff: '朝の入力',
  pickup: 'お迎えの入力',
  nonpickup_evening: '今夜の入力',
};

function localDaypart(): 'morning' | 'day' | 'evening' {
  const hour = new Date().getHours();
  if (hour < 11) return 'morning';
  if (hour < 17) return 'day';
  return 'evening';
}

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

function RequestQuickActions({
  request,
  onChanged,
}: {
  request: RequestRow;
  onChanged: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showOther, setShowOther] = useState(false);

  async function respond(kind: 'accept' | 'decline' | 'checking' | 'consult') {
    setBusy(true);
    setError(null);
    try {
      const functionName = kind === 'checking' || kind === 'consult'
        ? EDGE_FUNCTIONS.respondRequest
        : kind === 'accept' && request.assignment_task_instance_id
          ? EDGE_FUNCTIONS.acceptAssignmentChangeRequest
          : kind === 'accept' ? EDGE_FUNCTIONS.acceptRequest : EDGE_FUNCTIONS.declineRequest;
      await callEdgeFunction(functionName, {
        operation_id: newOperationId(),
        request_id: request.id,
        ...(kind === 'checking' || kind === 'consult' ? { response_action: kind } : {}),
      });
      onChanged();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。');
    } finally {
      setBusy(false);
    }
  }

  return (
    <li className="request-item">
      <div>
        <strong>{request.shared_title}</strong>
        {request.shared_message && <p>{request.shared_message}</p>}
        {request.due_at && (
          <span className="task-item-meta">期限: {formatDateTimeJa(request.due_at)}</span>
        )}
      </div>
      <div className="task-item-actions">
        <button type="button" disabled={busy} onClick={() => respond('accept')}>
          やる
        </button>
        <button type="button" disabled={busy} onClick={() => respond('decline')}>
          難しい
        </button>
        <button type="button" className="text-button" disabled={busy} onClick={() => setShowOther((value) => !value)}>
          その他の返答
        </button>
      </div>
      {showOther && (
        <div className="request-other-actions">
          <button type="button" className="secondary-button" disabled={busy} onClick={() => respond('checking')}>確認してみる</button>
          <button type="button" className="secondary-button" disabled={busy} onClick={() => respond('consult')}>相談する</button>
          <p className="task-item-meta">相談では、今の条件を二人で確認してから合意します。担当はこの時点では変わりません。</p>
        </div>
      )}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </li>
  );
}

export function Today() {
  const { user } = useAuth();
  const { household, members, me, partner } = useHousehold();
  const data = useTodayData(household?.id ?? null, user?.id ?? null);
  const schedule = useTodaySchedule(household?.id ?? null, user?.id ?? null);
  const pending = usePendingActions(household?.id ?? null, user?.id ?? null);
  const currentInputs = useCurrentRoutineSessions(Boolean(household?.id && user?.id));
  const tomorrowDate = useMemo(() => tokyoIsoDate(addDays(new Date(), 1)), []);
  const tomorrowPlanning = usePlanningData(household?.id ?? null, tomorrowDate, tomorrowDate);
  const navigate = useNavigate();
  const [editingTask, setEditingTask] = useState<TaskInstance | null>(null);
  const [correctionTitle, setCorrectionTitle] = useState<string | null>(null);
  const [editingPendingAction, setEditingPendingAction] = useState<PendingAction | null>(null);
  const [shoppingCollapsed, setShoppingCollapsed] = useState(true);
  const daypart = localDaypart();
  const isEvening = daypart === 'evening';
  const allDaySchedule = data.briefSchedule.filter((item) => item.is_all_day);

  const nextTask = useMemo(() => selectNextOwnedTask(data.tasks, me?.user_id), [data.tasks, me]);
  const todaySections = useMemo(() => {
    const transport = data.tasks.filter((task) => task.task_kind === 'transport');
    const handoffPreparation = data.tasks.filter(
      (task) => task.category === 'handover_preparation',
    );
    const morningPreparation = data.tasks.filter(
      (task) => task.task_kind === 'morning_preparation',
    );
    const morningChores = data.tasks.filter((task) => task.task_kind === 'morning_chore');
    const eveningChores = data.tasks.filter((task) => task.task_kind === 'evening_chore');
    const special = data.tasks.filter(
      (task) =>
        !transport.includes(task) &&
        !handoffPreparation.includes(task) &&
        !morningPreparation.includes(task) &&
        !morningChores.includes(task) &&
        !eveningChores.includes(task),
    );
    return {
      transport,
      handoffPreparation,
      morningPreparation,
      morningChores,
      eveningChores,
      special,
    };
  }, [data.tasks]);
  const tomorrowProjection = useMemo(
    () =>
      buildCalendarProjection({
        tasks: tomorrowPlanning.tasks,
        occurrences: tomorrowPlanning.occurrences,
        primaryUserId: papaUserId(members),
        partnerUserId: mamaUserId(members),
      }),
    [members, tomorrowPlanning.occurrences, tomorrowPlanning.tasks],
  );
  const tomorrowTransport = tomorrowProjection.transportByDate.get(tomorrowDate);
  const tomorrowItems = tomorrowProjection.itemsByDate.get(tomorrowDate) ?? [];
  const tomorrowMorningAssigneeId = tomorrowTransport?.dropoffAssigneeId ?? null;
  const tomorrowMorningAssigneeLabel = useMemo(() => {
    if (!tomorrowMorningAssigneeId) return '';
    const member = members.find((candidate) => candidate.user_id === tomorrowMorningAssigneeId);
    if (member?.family_role === 'papa') return 'パパ';
    if (member?.family_role === 'mama') return 'ママ';
    return member?.profile?.display_name ?? '担当あり';
  }, [members, tomorrowMorningAssigneeId]);
  const genericUnreadHandovers = data.unreadHandovers.filter(
    (handover) => !handover.categories?.includes('tomorrow_preparation'),
  );

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

  function renderOperationalSection(
    title: string,
    tasks: TaskInstance[],
    description?: string,
    options: { collapseWhenEvening?: boolean } = {},
  ) {
    if (tasks.length === 0) return null;
    const completedCount = tasks.filter((task) => task.status === 'completed').length;
    const activeTasks = tasks.filter((task) => task.status === 'todo' || task.status === 'in_progress');
    if (isEvening && options.collapseWhenEvening) {
      return (
        <section className="card compact-section task-section">
          <div className="section-heading">
            <div>
              <p className="eyebrow">朝のまとめ</p>
              <h2>{title} {completedCount}/{tasks.length}完了</h2>
            </div>
          </div>
          {activeTasks.length > 0 ? renderTaskList(activeTasks) : <p className="empty-hint">朝の残りはありません。</p>}
        </section>
      );
    }
    return (
      <section className="card task-section">
        <div className="section-heading">
          <div>
            <h2>{title}</h2>
            {description && <p className="empty-hint">{description}</p>}
          </div>
          <span>
            {completedCount}/{tasks.length}
          </span>
        </div>
        {renderTaskList(tasks)}
      </section>
    );
  }

  // needs_pwa_review is a sender-only draft. Moving it into either form must
  // not create, confirm, cancel, or reassign anything: the user can still
  // close the form without changing the household's business data. Only the
  // explicitly confirmed form submission creates a request or task.
  async function handleEditAsRequest(action: PendingAction) {
    navigate('/requests', {
      state: { pendingActionRawText: String(action.normalized_payload.raw_text ?? '') },
    });
  }

  async function handleEditAsTask(action: PendingAction) {
    setCorrectionTitle(String(action.normalized_payload.raw_text ?? ''));
  }

  if (data.loading) {
    return (
      <div className="app-shell">
        <p role="status">読み込み中…</p>
      </div>
    );
  }

  const hasPendingDecisions = data.incomingRequests.length > 0 || pending.pendingActions.length > 0;
  const waitingTasks = data.tasks.filter(
    (task) => task.attention_state === 'waiting' && (task.status === 'todo' || task.status === 'in_progress'),
  );
  const partnerCriticalTasks = data.tasks.filter(
    (task) => task.planned_assignee_id && task.planned_assignee_id !== me?.user_id &&
      (task.status === 'todo' || task.status === 'in_progress') &&
      (task.task_kind === 'transport' || Boolean(task.due_at)),
  );
  const preferredInputType: CurrentRoutineSessionType = daypart === 'morning'
    ? 'dropoff'
    : daypart === 'day'
      ? 'pickup'
      : 'nonpickup_evening';
  const currentInput = currentInputs.sessions.find(
    (session) => session.can_act && session.session_type === preferredInputType,
  ) ?? currentInputs.sessions.find((session) => session.can_act) ?? null;

  return (
    <div className="app-shell">
      <div className="today-header today-page-heading">
        <div>
          <p className="eyebrow">
            {new Intl.DateTimeFormat('ja-JP', {
              weekday: 'long',
              month: 'long',
              day: 'numeric',
            }).format(new Date())}{' '}
            · 今日の段取り
          </p>
          <h1>今日</h1>
        </div>
        <QuickAdd label="＋ 追加" ariaLabel="追加する" onTaskSaved={data.refresh} />
      </div>

      {data.error && (
        <p role="alert" className="error-text">
          {data.error}
        </p>
      )}

      <section className="today-shortcuts" aria-label="よく使う操作">
        {currentInput && (
          <button type="button" className="today-shortcut-primary" onClick={() => navigate(`/checkin/${currentInput.id}`)}>
            <span aria-hidden="true">{currentInput.session_type === 'nonpickup_evening' ? '🌙' : '📝'}</span>
            入力
          </button>
        )}
        <button type="button" onClick={() => navigate('/requests')}><span aria-hidden="true">🙏</span> お願い</button>
        <button type="button" onClick={() => navigate('/handovers')}><span aria-hidden="true">💬</span> 共有</button>
      </section>

      {currentInputs.error && <p role="status" className="empty-hint">{currentInputs.error}</p>}
      {currentInput && (
        <section className="card current-input-card" aria-label={INPUT_LABELS[currentInput.session_type]}>
          <div>
            <p className="eyebrow">{daypart === 'evening' ? '今日をしめくくる' : 'いま済ませる'}</p>
            <h2>{INPUT_LABELS[currentInput.session_type]}</h2>
            <p>{currentInput.remaining_count > 0 ? `残り ${currentInput.remaining_count}件。例外だけ詳しく入力できます。` : '入力する項目はありません。'}</p>
          </div>
          <button type="button" className="hero-primary" onClick={() => navigate(`/checkin/${currentInput.id}`)}>
            入力する
          </button>
        </section>
      )}

      {hasPendingDecisions && (
        <section className="card decision-card" aria-label="まず確認">
          <div className="section-heading">
            <div><p className="eyebrow">まず確認</p><h2>返事が必要です</h2></div>
            <span>{data.incomingRequests.length + pending.pendingActions.length}件</span>
          </div>
          {pending.error && <p role="alert" className="error-text">{pending.error}</p>}
          <ul className="request-list">
            {data.incomingRequests.map((request) => (
              <RequestQuickActions key={request.id} request={request} onChanged={data.refresh} />
            ))}
            {pending.pendingActions.map((action) => (
              <PendingActionCard key={action.id} action={action} onConfirm={pending.confirm} onCancel={pending.cancel} onEdit={setEditingPendingAction} onEditAsRequest={handleEditAsRequest} onEditAsTask={handleEditAsTask} />
            ))}
          </ul>
        </section>
      )}

      {waitingTasks.length > 0 && (
        <section className="card compact-section waiting-summary" aria-label="確認日">
          <div className="section-heading"><div><p className="eyebrow">確認日</p><h2>待ちにしていること</h2></div><span>{waitingTasks.length}件</span></div>
          {renderTaskList(waitingTasks)}
        </section>
      )}

      {genericUnreadHandovers.length > 0 && (
        <section className="card compact-section">
          <div className="section-heading"><div><p className="eyebrow">引き継ぎ・共有</p><h2>未読の引き継ぎ</h2></div></div>
          <ul className="handover-list">
            {genericUnreadHandovers.map((h) => (
              <li key={h.id} className="handover-item unread"><strong>{h.period}</strong> — {h.shared_text}</li>
            ))}
          </ul>
        </section>
      )}

      {nextTask && (
        <section className="next-action-hero" aria-labelledby="next-action-title">
          <span className="next-action-pill">次にやること</span>
          <p className="next-action-time">
            {nextTask.due_at
              ? new Date(nextTask.due_at).toLocaleTimeString('ja-JP', {
                  hour: '2-digit',
                  minute: '2-digit',
                })
              : '今日中'}
          </p>
          <h2 id="next-action-title">{nextTask.title}</h2>
          <p>
            {nextTask.planned_assignee_id === me?.user_id
              ? 'あなたの担当です。'
              : '担当と内容を確認しましょう。'}
          </p>
          <div className="next-action-actions">
            <button type="button" className="hero-primary" onClick={() => setEditingTask(nextTask)}>
              開く →
            </button>
            <button type="button" className="hero-secondary" onClick={() => navigate('/week')}>
              今回だけ変更
            </button>
          </div>
        </section>
      )}

      <TodaySchedule
        loading={schedule.loading}
        error={schedule.error}
        schedule={schedule.schedule}
        members={members}
      />

      {allDaySchedule.length > 0 && (
        <section className="card compact-section" aria-label="終日の予定">
          <div className="section-heading">
            <div>
              <p className="eyebrow">いつもと違うこと</p>
              <h2>終日の予定</h2>
            </div>
          </div>
          <ul className="today-schedule-list">
            {allDaySchedule.map((item) => (
              <li key={item.family_event_id ?? item.occurrence_key}>
                {item.title ?? '名称未設定'} <small>終日</small>
              </li>
            ))}
          </ul>
        </section>
      )}

      {!tomorrowPlanning.loading && (tomorrowTransport || tomorrowItems.length > 0) && (
        <section className="card compact-section" aria-label="明日の予定">
          <div className="section-heading">
            <div>
              <p className="eyebrow">先の見通し</p>
              <h2>明日の予定</h2>
            </div>
          </div>
          <ul className="today-schedule-list">
            {tomorrowTransport && (
              <li>{transportLabel(tomorrowTransport, papaUserId(members), mamaUserId(members))}</li>
            )}
            {tomorrowItems.map((item) => (
              <li key={item.id}>
                {item.shortTitle} <small>[{assigneeToken(item.ownerKind)}]</small>
              </li>
            ))}
          </ul>
          <button type="button" className="text-button" onClick={() => navigate('/week')}>
            週の予定を開く
          </button>
        </section>
      )}

      {renderOperationalSection(
        '昨夜からの持ち越し',
        data.carryoverTasks,
        '前夜の予定のまま、ここで完了できます。',
      )}
      {renderOperationalSection(
        '引き継ぎ・今日だけの準備',
        todaySections.handoffPreparation,
        '迎え担当から朝担当へ渡された持ち物です。終わったらその場でチェックしてください。',
      )}
      {renderOperationalSection('今日の送迎', todaySections.transport)}
      {renderOperationalSection('今日の特別対応', todaySections.special)}
      {renderOperationalSection('朝準備', todaySections.morningPreparation, undefined, { collapseWhenEvening: true })}
      {renderOperationalSection('朝の定例家事', todaySections.morningChores, undefined, { collapseWhenEvening: true })}

      <TomorrowPreparationCard
        tomorrowDate={tomorrowDate}
        assigneeId={tomorrowMorningAssigneeId}
        assigneeLabel={tomorrowMorningAssigneeLabel}
        onChanged={() => void data.refresh()}
      />

      {renderOperationalSection(
        '夜の定例作業',
        todaySections.eveningChores,
        '月・週には表示しません。',
      )}

      {partnerCriticalTasks.length > 0 && (
        <section className="card compact-section partner-summary" aria-label="相手の重要な予定">
          <p className="eyebrow">相手の重要な予定</p>
          <h2>ここだけ確認</h2>
          <ul className="today-schedule-list">
            {partnerCriticalTasks.slice(0, 3).map((task) => <li key={task.id}>{task.title}</li>)}
          </ul>
        </section>
      )}

      {data.openShoppingItems.length > 0 && (
        <section className="card collapsible compact-section">
          <button
            type="button"
            className="collapsible-toggle"
            onClick={() => setShoppingCollapsed((v) => !v)}
          >
            買い物（未購入 {data.openShoppingItems.length}件）{shoppingCollapsed ? '▼' : '▲'}
          </button>
          {!shoppingCollapsed && (
            <ul className="shopping-list-compact">
              {data.openShoppingItems.map((item) => (
                <li key={item.id}>{item.title}</li>
              ))}
            </ul>
          )}
        </section>
      )}

      {editingTask && (
        <TaskFormModal
          mode="edit"
          task={editingTask}
          onClose={() => setEditingTask(null)}
          onSaved={() => {
            setEditingTask(null);
            data.refresh();
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
            data.refresh();
          }}
        />
      )}
      {editingPendingAction && (
        <PendingActionEditModal
          action={editingPendingAction}
          onClose={() => setEditingPendingAction(null)}
          onSave={(actionType, payload) =>
            pending.update(editingPendingAction.id, actionType, payload)
          }
        />
      )}
    </div>
  );
}
