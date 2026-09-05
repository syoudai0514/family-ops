import { useAuth } from '../../app/AuthContext';
import { useHousehold, type HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import { formatDateTimeJa } from '../../lib/date';
import { tokyoIsoDate } from '../planning/dateHelpers';
import { useHistoryData, type HistoryEntry, type PlannedVsActualOutcome } from './useHistoryData';
import type { TaskEvent, TaskEventType } from '../../lib/types';
import { useEffect, useMemo, useState } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';

const OUTCOME_LABELS: Record<PlannedVsActualOutcome, string> = {
  completed_on_time: '完了（期限内）',
  completed_late: '完了（期限超過）',
  not_needed: '今回は不要',
  could_not_do: 'できなかった',
  expired_occurrence: '期限終了',
  waiting: '待ち',
  cancelled: 'キャンセル',
  overdue_open: '未完了（期限超過）',
  in_progress: '進行中',
  upcoming: '予定',
};

const OUTCOME_CLASS: Record<PlannedVsActualOutcome, string> = {
  completed_on_time: 'history-outcome ok',
  completed_late: 'history-outcome late',
  not_needed: 'history-outcome skipped',
  could_not_do: 'history-outcome skipped',
  expired_occurrence: 'history-outcome skipped',
  waiting: 'history-outcome pending',
  cancelled: 'history-outcome skipped',
  overdue_open: 'history-outcome late',
  in_progress: 'history-outcome pending',
  upcoming: 'history-outcome pending',
};

const EVENT_TYPE_LABELS: Record<TaskEventType, string> = {
  created: '作成', edited: '編集', cancelled: 'キャンセル', completed: '完了',
  subtask_completed: 'サブタスク完了', reassigned_once: '再割り当て', skipped: 'スキップ',
};

function memberLabel(userId: string | null, members: HouseholdMemberWithProfile[]): string {
  if (!userId) return '未定';
  const member = members.find((m) => m.user_id === userId);
  if (member?.family_role === 'papa') return 'パパ';
  if (member?.family_role === 'mama') return 'ママ';
  return member?.profile?.display_name ?? userId;
}

function EventTrail({ events, members }: { events: TaskEvent[]; members: HouseholdMemberWithProfile[] }) {
  if (events.length === 0) return null;
  return <ul className="history-event-trail">{events.map((event) => <li key={event.id}><span className="task-item-meta">{formatDateTimeJa(event.created_at)} · {EVENT_TYPE_LABELS[event.event_type] ?? event.event_type} · {memberLabel(event.actor_id, members)}</span></li>)}</ul>;
}

export function reassignmentSummary(events: TaskEvent[], members: HouseholdMemberWithProfile[]): string | null {
  const event = [...events].reverse().find((candidate) => candidate.event_type === 'reassigned_once');
  if (!event) return null;
  const oldId = typeof event.payload.old_assignee_id === 'string' ? event.payload.old_assignee_id : typeof event.payload.from === 'string' ? event.payload.from : null;
  const newId = typeof event.payload.new_assignee_id === 'string' ? event.payload.new_assignee_id : typeof event.payload.to === 'string' ? event.payload.to : null;
  if (!oldId || !newId) return '担当変更';
  return `担当変更: ${memberLabel(oldId, members)} → ${memberLabel(newId, members)}`;
}

export function completedNextTokyoMorning(scheduledDate: string, completedAt: string | null): boolean {
  return Boolean(completedAt && tokyoIsoDate(completedAt) > scheduledDate);
}

function HistoryRow({ entry, members, onChanged }: { entry: HistoryEntry; members: HouseholdMemberWithProfile[]; onChanged: () => Promise<void> }) {
  const { task, outcome, events, wasReassigned, actualParticipantUserIds } = entry;
  const reassignment = wasReassigned ? reassignmentSummary(events, members) : null;
  const [editingActual, setEditingActual] = useState(false);
  const [selectedUserIds, setSelectedUserIds] = useState<string[]>(actualParticipantUserIds);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { if (!editingActual) setSelectedUserIds(actualParticipantUserIds); }, [actualParticipantUserIds, editingActual]);

  async function saveActualCorrection() {
    if (selectedUserIds.length === 0) {
      setError('実施した人を一人以上選んでください。');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.correctTaskActual, {
        operation_id: newOperationId(), task_id: task.id,
        participant_user_ids: selectedUserIds, expected_revision: task.revision ?? 1,
      });
      setEditingActual(false);
      await onChanged();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '訂正に失敗しました。');
    } finally {
      setBusy(false);
    }
  }

  return <li className="history-item card">
    <div className="history-item-header"><strong>{task.title}</strong><span className={OUTCOME_CLASS[outcome]}>{OUTCOME_LABELS[outcome]}</span></div>
    <p className="task-item-meta">予定: {task.due_at ? formatDateTimeJa(task.due_at) : task.scheduled_date} {memberLabel(task.planned_assignee_id, members)}</p>
    {task.status === 'completed' && <p className="task-item-meta">実績: {task.completed_at ? formatDateTimeJa(task.completed_at) : '—'} {actualParticipantUserIds.map((id) => memberLabel(id, members)).join('・') || '未記録'}{completedNextTokyoMorning(task.scheduled_date, task.completed_at) ? ' · 翌朝に完了' : ''}</p>}
    {outcome === 'waiting' && <p className="task-item-meta">{task.waiting_note ? `待ち理由: ${task.waiting_note}` : '確認待ち'}{task.next_check_at ? ` · 次回確認 ${formatDateTimeJa(task.next_check_at)}` : ''}</p>}
    {reassignment && <p className="task-item-meta">{reassignment}</p>}
    {task.status === 'completed' && (
      <div className="history-correction">
        {!editingActual ? <button type="button" className="text-button" onClick={() => setEditingActual(true)}>実績を訂正</button> : (
          <fieldset>
            <legend>実際にやった人</legend>
            {members.map((member) => {
              const checked = selectedUserIds.includes(member.user_id);
              return <label key={member.user_id} className="inline-check"><input type="checkbox" checked={checked} disabled={busy} onChange={() => setSelectedUserIds((ids) => checked ? ids.filter((id) => id !== member.user_id) : [...ids, member.user_id])} />{memberLabel(member.user_id, members)}</label>;
            })}
            <p className="task-item-meta">訂正前の記録は履歴に残ります。</p>
            <div className="task-item-actions"><button type="button" disabled={busy} onClick={saveActualCorrection}>訂正を保存</button><button type="button" className="text-button" disabled={busy} onClick={() => setEditingActual(false)}>やめる</button></div>
          </fieldset>
        )}
        {error && <p role="alert" className="error-text">{error}</p>}
      </div>
    )}
    <EventTrail events={events} members={members} />
  </li>;
}

export function HistoryPage() {
  const { user } = useAuth();
  const { household, members } = useHousehold();
  const { loading, error, entries } = useHistoryData(household?.id ?? null, user?.id ?? null);
  const [filter, setFilter] = useState<'all' | 'routine' | 'planned' | 'request'>('all');
  const visibleEntries = useMemo(() => entries.filter((entry) => {
    if (filter === 'all') return true;
    if (filter === 'routine') return entry.task.routine_phase === 'morning' || entry.task.routine_phase === 'evening';
    if (filter === 'planned') return entry.task.routine_phase !== 'morning' && entry.task.routine_phase !== 'evening';
    return entry.events.some((event) => event.source === 'request');
  }), [entries, filter]);

  if (loading) return <div className="app-shell"><p role="status">読み込み中…</p></div>;

  return <div className="app-shell">
    <div className="today-header"><h1>履歴</h1></div>
    <p className="task-item-meta">直近2週間の予定と実際の結果です。</p>
    <div className="filter-chips" aria-label="履歴の絞り込み">
      {([['all', 'すべて'], ['routine', '定例作業'], ['planned', '予定'], ['request', 'お願い']] as const).map(([key, label]) => <button key={key} type="button" className={filter === key ? 'active' : ''} onClick={() => setFilter(key)}>{label}</button>)}
    </div>
    {error && <p role="alert" className="error-text">{error}</p>}
    <ul className="history-list">{visibleEntries.length === 0 && <li className="empty-hint">この条件の記録はありません。</li>}{visibleEntries.map((entry) => <HistoryRow key={entry.task.id} entry={entry} members={members} onChanged={refresh} />)}</ul>
  </div>;
}
