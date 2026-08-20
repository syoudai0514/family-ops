import { useAuth } from '../../app/AuthContext';
import { useHousehold, type HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import { formatDateTimeJa } from '../../lib/date';
import { useHistoryData, type HistoryEntry, type PlannedVsActualOutcome } from './useHistoryData';
import type { TaskEvent, TaskEventType } from '../../lib/types';

// WP4 — planned vs actual history view. Read-only: no score, ranking, or
// "who did more" comparison is shown here or ever should be (see
// docs/design/v6/10_WORK_PACKAGES.md, WP4 "no score/ranking").
const OUTCOME_LABELS: Record<PlannedVsActualOutcome, string> = {
  completed_on_time: '完了（期限内）',
  completed_late: '完了（期限超過）',
  skipped: 'スキップ',
  cancelled: 'キャンセル',
  overdue_open: '未完了（期限超過）',
  in_progress: '進行中',
  upcoming: '予定',
};

const OUTCOME_CLASS: Record<PlannedVsActualOutcome, string> = {
  completed_on_time: 'history-outcome ok',
  completed_late: 'history-outcome late',
  skipped: 'history-outcome skipped',
  cancelled: 'history-outcome skipped',
  overdue_open: 'history-outcome late',
  in_progress: 'history-outcome pending',
  upcoming: 'history-outcome pending',
};

const EVENT_TYPE_LABELS: Record<TaskEventType, string> = {
  created: '作成',
  edited: '編集',
  cancelled: 'キャンセル',
  completed: '完了',
  subtask_completed: 'サブタスク完了',
  reassigned_once: '再割り当て',
  skipped: 'スキップ',
};

function memberLabel(userId: string | null, members: HouseholdMemberWithProfile[]): string {
  if (!userId) return '未定';
  const member = members.find((m) => m.user_id === userId);
  return member?.profile?.display_name ?? userId;
}

function EventTrail({ events, members }: { events: TaskEvent[]; members: HouseholdMemberWithProfile[] }) {
  if (events.length === 0) return null;
  return (
    <ul className="history-event-trail">
      {events.map((event) => (
        <li key={event.id}>
          <span className="task-item-meta">
            {formatDateTimeJa(event.created_at)} · {EVENT_TYPE_LABELS[event.event_type] ?? event.event_type} ·{' '}
            {memberLabel(event.actor_id, members)}
          </span>
        </li>
      ))}
    </ul>
  );
}

function HistoryRow({ entry, members }: { entry: HistoryEntry; members: HouseholdMemberWithProfile[] }) {
  const { task, outcome, events, wasReassigned } = entry;
  return (
    <li className="history-item card">
      <div className="history-item-header">
        <strong>{task.title}</strong>
        <span className={OUTCOME_CLASS[outcome]}>{OUTCOME_LABELS[outcome]}</span>
      </div>
      <p className="task-item-meta">
        予定: {task.scheduled_date}
        {task.due_at ? ` · 期限 ${formatDateTimeJa(task.due_at)}` : ''} · 担当予定: {memberLabel(task.planned_assignee_id, members)}
      </p>
      {task.status === 'completed' && (
        <p className="task-item-meta">
          実際: {task.completed_at ? formatDateTimeJa(task.completed_at) : '—'} · 実施者:{' '}
          {memberLabel(task.actual_completed_by_id, members)}
        </p>
      )}
      {wasReassigned && <p className="task-item-meta">この予定は再割り当てされました。</p>}
      <EventTrail events={events} members={members} />
    </li>
  );
}

export function HistoryPage() {
  const { user } = useAuth();
  const { household, members } = useHousehold();
  const { loading, error, entries } = useHistoryData(household?.id ?? null, user?.id ?? null);

  if (loading) {
    return (
      <div className="app-shell">
        <p role="status">読み込み中…</p>
      </div>
    );
  }

  return (
    <div className="app-shell">
      <div className="today-header">
        <h1>履歴</h1>
      </div>
      <p className="task-item-meta">直近2週間の予定と実際の結果です。</p>

      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}

      <ul className="history-list">
        {entries.length === 0 && <li className="empty-hint">この期間の記録はありません。</li>}
        {entries.map((entry) => (
          <HistoryRow key={entry.task.id} entry={entry} members={members} />
        ))}
      </ul>
    </div>
  );
}
