import { useMemo, useState } from 'react';
import { useAuth } from '../../app/AuthContext';
import { useHousehold } from '../../app/HouseholdContext';
import { useTodayData } from './useTodayData';
import { usePendingActions } from './usePendingActions';
import { useTodaySchedule } from './useTodaySchedule';
import { TodayTaskItem } from './TodayTaskItem';
import { TodaySchedule } from './TodaySchedule';
import { PendingActionCard } from './PendingActionCard';
import { TaskFormModal } from '../tasks/TaskFormModal';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { formatDateTimeJa } from '../../lib/date';
import type { PendingAction, RequestRow, TaskInstance } from '../../lib/types';

function RequestQuickActions({ request, onChanged }: { request: RequestRow; onChanged: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function respond(kind: 'accept' | 'decline') {
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(kind === 'accept' ? EDGE_FUNCTIONS.acceptRequest : EDGE_FUNCTIONS.declineRequest, {
        operation_id: newOperationId(),
        request_id: request.id,
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
        {request.due_at && <span className="task-item-meta">期限: {formatDateTimeJa(request.due_at)}</span>}
      </div>
      <div className="task-item-actions">
        <button type="button" disabled={busy} onClick={() => respond('accept')}>
          引き受ける
        </button>
        <button type="button" disabled={busy} onClick={() => respond('decline')}>
          断る
        </button>
      </div>
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
  const [creating, setCreating] = useState(false);
  const [editingTask, setEditingTask] = useState<TaskInstance | null>(null);
  const [correctionTitle, setCorrectionTitle] = useState<string | null>(null);
  const [shoppingCollapsed, setShoppingCollapsed] = useState(true);

  const { myTasks, partnerTasks, unassignedTasks } = useMemo(() => {
    const mine: TaskInstance[] = [];
    const partnerList: TaskInstance[] = [];
    const unassigned: TaskInstance[] = [];
    for (const task of data.tasks) {
      if (!task.planned_assignee_id) unassigned.push(task);
      else if (task.planned_assignee_id === me?.user_id) mine.push(task);
      else partnerList.push(task);
    }
    return { myTasks: mine, partnerTasks: partnerList, unassignedTasks: unassigned };
  }, [data.tasks, me]);

  function renderTaskList(tasks: TaskInstance[]) {
    if (tasks.length === 0) return <p className="empty-hint">なし</p>;
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

  // A needs_pwa_review draft has no execution path (process-pending-actions
  // has no case for it) — "編集してPWAフォームへ" cancels the ambiguous draft
  // and hands the sender's own raw text to the normal task form as a
  // starting point instead, matching "usable correction/form path rather
  // than a dead end" (docs/adr/0011).
  async function handleEditInForm(action: PendingAction) {
    await pending.cancel(action.id);
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

  return (
    <div className="app-shell">
      <div className="today-header">
        <h1>今日</h1>
        <button type="button" onClick={() => setCreating(true)}>
          + タスクを追加
        </button>
      </div>

      {data.error && (
        <p role="alert" className="error-text">
          {data.error}
        </p>
      )}

      {/* Priority 1: 今/次の予定 */}
      <TodaySchedule loading={schedule.loading} error={schedule.error} schedule={schedule.schedule} members={members} />

      {/* Priority 2: 自分の判断待ち */}
      <section className="card">
        <h2>判断待ち</h2>
        {pending.error && (
          <p role="alert" className="error-text">
            {pending.error}
          </p>
        )}
        {!hasPendingDecisions ? (
          <p className="empty-hint">なし</p>
        ) : (
          <ul className="request-list">
            {data.incomingRequests.map((request) => (
              <RequestQuickActions key={request.id} request={request} onChanged={data.refresh} />
            ))}
            {pending.pendingActions.map((action) => (
              <PendingActionCard
                key={action.id}
                action={action}
                onConfirm={pending.confirm}
                onCancel={pending.cancel}
                onEditInForm={handleEditInForm}
              />
            ))}
          </ul>
        )}
      </section>

      {/* Priority 3: 今日の自分のタスク */}
      <section className="card">
        <h2>自分のタスク</h2>
        {renderTaskList(myTasks)}
      </section>

      <section className="card">
        <h2>パートナーのタスク</h2>
        {renderTaskList(partnerTasks)}
      </section>

      {unassignedTasks.length > 0 && (
        <section className="card">
          <h2>未割り当て</h2>
          {renderTaskList(unassignedTasks)}
        </section>
      )}

      {/* Priority 4: 重要な引き継ぎ */}
      <section className="card">
        <h2>未読の引き継ぎ</h2>
        {data.unreadHandovers.length === 0 ? (
          <p className="empty-hint">なし</p>
        ) : (
          <ul className="handover-list">
            {data.unreadHandovers.map((h) => (
              <li key={h.id} className="handover-item unread">
                <strong>{h.period}</strong> — {h.shared_text}
              </li>
            ))}
          </ul>
        )}
      </section>

      {/* Priority 5: 折りたたみ */}
      <section className="card collapsible">
        <button type="button" className="collapsible-toggle" onClick={() => setShoppingCollapsed((v) => !v)}>
          買い物（未購入 {data.openShoppingItems.length}件）{shoppingCollapsed ? '▼' : '▲'}
        </button>
        {!shoppingCollapsed && (
          <ul className="shopping-list-compact">
            {data.openShoppingItems.length === 0 ? (
              <li className="empty-hint">なし</li>
            ) : (
              data.openShoppingItems.map((item) => <li key={item.id}>{item.title}</li>)
            )}
          </ul>
        )}
      </section>

      {creating && (
        <TaskFormModal
          mode="create"
          onClose={() => setCreating(false)}
          onSaved={() => {
            setCreating(false);
            data.refresh();
          }}
        />
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
    </div>
  );
}
