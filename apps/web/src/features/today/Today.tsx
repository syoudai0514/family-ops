import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
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

  async function respond(kind: 'accept' | 'decline') {
    setBusy(true);
    setError(null);
    try {
      const functionName =
        kind === 'accept' && request.assignment_task_instance_id
          ? EDGE_FUNCTIONS.acceptAssignmentChangeRequest
          : kind === 'accept'
            ? EDGE_FUNCTIONS.acceptRequest
            : EDGE_FUNCTIONS.declineRequest;
      await callEdgeFunction(functionName, {
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
        {request.due_at && (
          <span className="task-item-meta">期限: {formatDateTimeJa(request.due_at)}</span>
        )}
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
  const navigate = useNavigate();
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

  const nextTask = useMemo(() => selectNextOwnedTask(data.tasks, me?.user_id), [data.tasks, me]);

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
        <button type="button" onClick={() => setCreating(true)}>
          ＋ 追加
        </button>
      </div>

      {data.error && (
        <p role="alert" className="error-text">
          {data.error}
        </p>
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

      {/* Priority 2: 今/次の予定 */}
      <TodaySchedule
        loading={schedule.loading}
        error={schedule.error}
        schedule={schedule.schedule}
        members={members}
      />

      {/* Priority 3: 自分の残り */}
      {myTasks.length > 0 && (
        <section className="card task-section">
          <div className="section-heading">
            <h2>自分の残り</h2>
            <span>{myTasks.length}件</span>
          </div>
          {renderTaskList(myTasks)}
        </section>
      )}

      {partnerTasks.length > 0 && (
        <details className="card partner-summary">
          <summary>パートナーの残り {partnerTasks.length}件</summary>
          {renderTaskList(partnerTasks)}
        </details>
      )}

      {unassignedTasks.length > 0 && (
        <section className="card">
          <h2>未割り当て</h2>
          {renderTaskList(unassignedTasks)}
        </section>
      )}

      {/* 判断待ちは、今日の実行情報を見た後に、あるときだけ表示する。 */}
      {hasPendingDecisions && (
        <section className="card decision-card">
          <div className="section-heading">
            <div>
              <p className="eyebrow">返事が必要です</p>
              <h2>判断待ち</h2>
            </div>
            <span>{data.incomingRequests.length + pending.pendingActions.length}件</span>
          </div>
          {pending.error && (
            <p role="alert" className="error-text">
              {pending.error}
            </p>
          )}
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
                onEditAsRequest={handleEditAsRequest}
                onEditAsTask={handleEditAsTask}
              />
            ))}
          </ul>
        </section>
      )}

      {/* Priority 4: 重要な引き継ぎ */}
      {data.unreadHandovers.length > 0 && (
        <section className="card compact-section">
          <h2>未読の引き継ぎ</h2>
          <ul className="handover-list">
            {data.unreadHandovers.map((h) => (
              <li key={h.id} className="handover-item unread">
                <strong>{h.period}</strong> — {h.shared_text}
              </li>
            ))}
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
