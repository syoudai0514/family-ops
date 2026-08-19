import { useMemo, useState } from 'react';
import { useAuth } from '../../app/AuthContext';
import { useHousehold } from '../../app/HouseholdContext';
import { useTodayData } from './useTodayData';
import { TodayTaskItem } from './TodayTaskItem';
import { TaskFormModal } from '../tasks/TaskFormModal';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { formatDateTimeJa } from '../../lib/date';
import type { RequestRow, TaskInstance } from '../../lib/types';

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
  const [creating, setCreating] = useState(false);
  const [editingTask, setEditingTask] = useState<TaskInstance | null>(null);
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

  if (data.loading) {
    return (
      <div className="app-shell">
        <p role="status">読み込み中…</p>
      </div>
    );
  }

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

      <section className="card">
        <h2>届いているお願い</h2>
        {data.incomingRequests.length === 0 ? (
          <p className="empty-hint">なし</p>
        ) : (
          <ul className="request-list">
            {data.incomingRequests.map((request) => (
              <RequestQuickActions key={request.id} request={request} onChanged={data.refresh} />
            ))}
          </ul>
        )}
      </section>

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
    </div>
  );
}
