import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../../app/AuthContext';
import { useHousehold } from '../../app/HouseholdContext';
import type { TaskInstance } from '../../lib/types';
import { useCurrentRoutineSessions, type CurrentRoutineSessionType } from '../checkin/useCurrentRoutineSessions';
import { addDays, tokyoIsoDate } from '../planning/dateHelpers';
import { usePlanningData } from '../planning/usePlanningData';
import { TaskFormModal } from '../tasks/TaskFormModal';
import { TodayTaskItem } from './TodayTaskItem';
import { usePendingActions } from './usePendingActions';
import { useTodayData } from './useTodayData';
import { shouldShowWaitingTask, Today } from './Today';

export interface TodayContractSummary {
  attention: number;
  remaining: number;
  waiting: number;
  tomorrowImpact: number;
}

export function buildTodayContractSummary(args: {
  incomingRequestCount: number;
  pendingActionCount: number;
  currentUserId?: string | null;
  tasks: Array<{
    status: string;
    planned_assignee_id?: string | null;
    attention_state?: string | null;
    next_check_at?: string | null;
    due_at?: string | null;
  }>;
  tomorrowTaskCount: number;
  tomorrowOccurrenceCount: number;
}): TodayContractSummary {
  const activeTasks = args.tasks.filter((task) => task.status === 'todo' || task.status === 'in_progress');
  const waitingTasks = activeTasks.filter((task) => shouldShowWaitingTask(task as never));
  const unassigned = activeTasks.filter((task) => !task.planned_assignee_id).length;
  const ownedActive = args.currentUserId
    ? activeTasks.filter(
        (task) => task.planned_assignee_id === args.currentUserId && !shouldShowWaitingTask(task as never),
      )
    : activeTasks.filter((task) => !shouldShowWaitingTask(task as never));

  return {
    attention: args.incomingRequestCount + args.pendingActionCount + unassigned,
    remaining: ownedActive.length,
    waiting: waitingTasks.length,
    tomorrowImpact: args.tomorrowTaskCount + args.tomorrowOccurrenceCount,
  };
}

function jumpTo(selector: string, fallback: () => void) {
  const target = document.querySelector<HTMLElement>(selector);
  if (target) {
    target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    return;
  }
  fallback();
}

function todayHeading() {
  return new Intl.DateTimeFormat('ja-JP', {
    timeZone: 'Asia/Tokyo',
    weekday: 'long',
    month: 'long',
    day: 'numeric',
  }).format(new Date());
}

function localDaypart(): 'morning' | 'day' | 'evening' {
  const hour = Number(new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Tokyo',
    hour: '2-digit',
    hourCycle: 'h23',
  }).format(new Date()));
  if (hour < 11) return 'morning';
  if (hour < 17) return 'day';
  return 'evening';
}

function isMorningTask(task: TaskInstance) {
  return task.routine_phase === 'morning' || task.task_kind === 'morning_preparation' || task.task_kind === 'morning_chore';
}

function active(task: TaskInstance) {
  return task.status === 'todo' || task.status === 'in_progress';
}

function pendingTitle(action: { normalized_payload?: Record<string, unknown> }) {
  const payload = action.normalized_payload ?? {};
  for (const key of ['title', 'shared_title', 'raw_text']) {
    const value = payload[key];
    if (typeof value === 'string' && value.trim()) return value.trim();
  }
  return '確認待ちの内容';
}

function dedupeTasks(tasks: TaskInstance[]) {
  return [...new Map(tasks.map((task) => [task.id, task])).values()];
}

export function TodayContractPage() {
  const { user } = useAuth();
  const { household, members, partner } = useHousehold();
  const navigate = useNavigate();
  const today = useTodayData(household?.id ?? null, user?.id ?? null);
  const pending = usePendingActions(household?.id ?? null, user?.id ?? null);
  const currentInputs = useCurrentRoutineSessions(Boolean(household?.id && user?.id));
  const [editingTask, setEditingTask] = useState<TaskInstance | null>(null);
  const daypart = localDaypart();
  const tomorrowDate = useMemo(() => tokyoIsoDate(addDays(new Date(), 1)), []);
  const tomorrow = usePlanningData(household?.id ?? null, tomorrowDate, tomorrowDate);
  const summary = buildTodayContractSummary({
    incomingRequestCount: today.incomingRequests.length,
    pendingActionCount: pending.pendingActions.length,
    currentUserId: user?.id ?? null,
    tasks: today.tasks,
    tomorrowTaskCount: tomorrow.tasks.length,
    tomorrowOccurrenceCount: tomorrow.occurrences.length,
  });

  const activeTodayTasks = today.tasks.filter(active);
  const waitingTasks = activeTodayTasks.filter((task) => shouldShowWaitingTask(task));
  const unassignedTasks = activeTodayTasks.filter((task) => !task.planned_assignee_id);
  const workTasks = dedupeTasks([
    ...today.carryoverTasks,
    ...today.tasks,
  ]).filter((task) => {
    if (!active(task) || shouldShowWaitingTask(task)) return false;
    if (task.planned_assignee_id && task.planned_assignee_id !== user?.id) return false;
    if (daypart === 'evening' && isMorningTask(task)) return false;
    return true;
  });
  const morningTasks = today.tasks.filter(isMorningTask);
  const completedMorningCount = morningTasks.filter((task) => task.status === 'completed').length;
  const partnerTasks = activeTodayTasks.filter(
    (task) => Boolean(task.planned_assignee_id) && task.planned_assignee_id !== user?.id,
  );
  const preHandledTasks = today.tasks.filter(
    (task) =>
      task.status === 'completed' &&
      task.planned_assignee_id === user?.id &&
      Boolean(task.actual_completed_by_id) &&
      task.actual_completed_by_id !== user?.id,
  );
  const tomorrowTitles = [
    ...tomorrow.tasks.map((task) => task.title),
    ...tomorrow.occurrences.map((occurrence) => occurrence.title),
  ].filter(Boolean);

  const preferredInputType: CurrentRoutineSessionType = daypart === 'morning'
    ? 'dropoff'
    : daypart === 'day'
      ? 'pickup'
      : 'nonpickup_evening';
  const currentInput = currentInputs.sessions.find(
    (session) => session.can_act && session.session_type === preferredInputType,
  ) ?? currentInputs.sessions.find((session) => session.can_act) ?? null;

  const workEyebrow = daypart === 'morning' ? '🌅 朝にやること' : '📝 今日やること';
  const workHeading = daypart === 'morning'
    ? '朝にやること'
    : daypart === 'evening'
      ? '夜に残っていること'
      : '今日やること';

  function renderTaskList(tasks: TaskInstance[]) {
    return (
      <ul className="task-list today-contract-task-list">
        {tasks.map((task) => (
          <TodayTaskItem
            key={task.id}
            task={task}
            subtasks={today.subtasksByTaskId.get(task.id) ?? []}
            members={members}
            hasPartner={Boolean(partner)}
            onEdit={setEditingTask}
            onChanged={today.refresh}
          />
        ))}
      </ul>
    );
  }

  return (
    <div className="today-contract-flow">
      <section className="app-shell today-contract-overview" aria-label="今日の状況">
        <div className="today-contract-page-head">
          <div>
            <p className="eyebrow">{todayHeading()} · 今日の段取り</p>
            <h1>今日</h1>
          </div>
          <span className="today-contract-current-badge">現在時刻で再計算</span>
        </div>

        <div className="card compact-section">
          <div className="section-heading">
            <div>
              <p className="eyebrow">最初にここだけ見ればOK</p>
              <h2>今日の状況</h2>
            </div>
            <button type="button" className="text-button" onClick={() => navigate('/concierge', { state: { originPath: '/today', originScrollY: window.scrollY } })}>✨ コンシェルジュ</button>
          </div>
          <div className="today-contract-shortcuts" aria-label="今日の要点へ移動">
            <button type="button" onClick={() => jumpTo('#today-contract-attention', () => navigate('/requests'))}><small>返事・担当未定</small><strong>要対応 {summary.attention}</strong></button>
            <button type="button" onClick={() => jumpTo('#today-contract-work', () => undefined)}><small>今日の自分タスク</small><strong>残り {summary.remaining}</strong></button>
            <button type="button" onClick={() => jumpTo('#today-contract-waiting', () => undefined)}><small>待ち・あとで確認</small><strong>待ち {summary.waiting}</strong></button>
            <button type="button" onClick={() => jumpTo('#today-contract-tomorrow', () => navigate('/week'))}><small>明日の予定・準備</small><strong>明日影響 {summary.tomorrowImpact}</strong></button>
          </div>
        </div>

        {(today.incomingRequests.length > 0 || pending.pendingActions.length > 0 || unassignedTasks.length > 0) && (
          <section className="card today-contract-section today-contract-danger" id="today-contract-attention" aria-label="放置すると困ること">
            <div className="section-heading">
              <div><p className="eyebrow">🔴 まず確認</p><h2>放置すると困ること</h2></div>
              <span>{summary.attention}件</span>
            </div>
            <div className="today-contract-compact-list">
              {today.incomingRequests.map((request) => (
                <div className="today-contract-list-row" key={`request:${request.id}`}>
                  <div><strong>{request.shared_title}</strong>{request.due_at && <small>返事・期限の確認が必要です</small>}</div>
                  <button type="button" className="secondary-button" onClick={() => navigate('/requests')}>返事する</button>
                </div>
              ))}
              {pending.pendingActions.map((action) => (
                <div className="today-contract-list-row" key={`pending:${action.id}`}>
                  <div><strong>{pendingTitle(action)}</strong><small>確認待ち</small></div>
                  <button type="button" className="secondary-button" onClick={() => jumpTo('.decision-card', () => undefined)}>確認する</button>
                </div>
              ))}
              {unassignedTasks.map((task) => (
                <div className="today-contract-list-row" key={`unassigned:${task.id}`}>
                  <div><strong>{task.title}</strong><small>担当未定</small></div>
                  <button type="button" className="secondary-button" onClick={() => navigate('/week')}>担当を決める</button>
                </div>
              ))}
            </div>
          </section>
        )}

        {daypart === 'evening' && morningTasks.length > 0 && (
          <section className="card today-contract-section today-contract-done" aria-label="もう済んでいること">
            <div className="section-heading">
              <div><p className="eyebrow">✅ もう済んでいること</p><h2>朝 {completedMorningCount}/{morningTasks.length} 完了</h2></div>
              {completedMorningCount === morningTasks.length && <span>完了</span>}
            </div>
            <p className="empty-hint">夜は完了済み朝タスクをもう一度並べません。未入力の確認は実績入力から行えます。</p>
          </section>
        )}

        <section className="card today-contract-section today-contract-work" id="today-contract-work" aria-label="今日やること">
          <div className="section-heading">
            <div><p className="eyebrow">{workEyebrow}</p><h2>{workHeading}</h2></div>
            <span>{workTasks.length}件</span>
          </div>
          {workTasks.length > 0 ? renderTaskList(workTasks) : <p className="empty-hint">今の時間帯に残っているタスクはありません。</p>}
          {currentInput && (
            <button type="button" className="hero-primary today-contract-bulk-input" onClick={() => navigate(`/checkin/${currentInput.id}`)}>
              {currentInput.remaining_count > 0 ? `${currentInput.remaining_count}件をまとめて入力` : '実績を入力'}
            </button>
          )}
          {currentInputs.error && <p role="status" className="empty-hint">{currentInputs.error}</p>}
        </section>

        {waitingTasks.length > 0 && (
          <section className="card today-contract-section" id="today-contract-waiting" aria-label="待ち">
            <div className="section-heading"><div><p className="eyebrow">待ち</p><h2>あとで確認すること</h2></div><span>{waitingTasks.length}件</span></div>
            {renderTaskList(waitingTasks)}
          </section>
        )}

        {summary.tomorrowImpact > 0 && (
          <section className="card today-contract-section today-contract-tomorrow" id="today-contract-tomorrow" aria-label="明日に影響">
            <div className="section-heading"><div><p className="eyebrow">明日に影響</p><h2>明日の予定・準備</h2></div><span>{summary.tomorrowImpact}件</span></div>
            {tomorrowTitles.length > 0 && (
              <ul className="today-schedule-list">
                {tomorrowTitles.slice(0, 4).map((title, index) => <li key={`${title}:${index}`}>{title}</li>)}
              </ul>
            )}
            <button type="button" className="secondary-button" onClick={() => navigate('/week')}>明日の詳細</button>
          </section>
        )}

        {partnerTasks.length > 0 && (
          <section className="card today-contract-section" aria-label="相手の今日">
            <div className="section-heading">
              <div><p className="eyebrow">相手の今日</p><h2>相手は通常要約</h2></div>
              <button type="button" className="text-button" onClick={() => navigate('/week')}>相手の分も見る</button>
            </div>
            <p className="empty-hint">今日 {partnerTasks.length}件。自分に影響する内容は別途具体表示します。</p>
          </section>
        )}

        {preHandledTasks.length > 0 && (
          <section className="card today-contract-section today-contract-success" aria-label="負担が減った前倒し">
            <p className="eyebrow">負担が減った前倒しだけ表示</p>
            <h2>{preHandledTasks[0].title} は相手が対応済み</h2>
            <p className="empty-hint">あなたの今日の作業が{preHandledTasks.length}件減りました。</p>
          </section>
        )}
      </section>

      <Today />

      {editingTask && (
        <TaskFormModal
          mode="edit"
          task={editingTask}
          onClose={() => setEditingTask(null)}
          onSaved={() => {
            setEditingTask(null);
            void today.refresh();
          }}
        />
      )}
    </div>
  );
}
