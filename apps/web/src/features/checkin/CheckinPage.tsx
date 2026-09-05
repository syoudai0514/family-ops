// Route: /checkin/:sessionId -> CheckinPage
// docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md #8 "PWA deep link"; #9 "PWA
// check-in screen". Reached from the LINE deep link
// `{APP_BASE_URL}/checkin/{session_id}` (no bearer secret in the URL — the
// session's own bearer token from the already-authenticated PWA session is
// what authorizes every call here) or directly from the PWA's own routine
// session list. AuthGate is expected to handle the logged-out ->
// Google Sign-In -> returnTo-back-to-this-URL flow upstream of this
// component (out of this feature's scope — this component assumes an
// authenticated `user` is already available, same assumption every other
// feature/*.tsx makes).
import { useCallback, useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { useAuth } from '../../app/AuthContext';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';

type SessionType = 'dropoff' | 'pickup' | 'nonpickup_evening';
type SessionStatus = 'open' | 'submitted' | 'auto_closed' | 'superseded';
type ItemAction = 'complete' | 'partner_handled' | 'skip';
type ReconciliationResponse = 'all_done' | 'mostly_done' | 'individual';

interface SubtaskRow {
  id: string;
  title: string;
  required: boolean;
  is_completed: boolean;
  completed_by: string | null;
}

interface SessionItem {
  task_instance_id: string;
  title: string;
  status: 'todo' | 'in_progress' | 'completed' | 'skipped' | 'cancelled';
  completion_mode: 'whole' | 'subtasks';
  actual_completed_by_id: string | null;
  display_order: number;
  subtasks: SubtaskRow[];
}

interface RoutineSession {
  id: string;
  session_type: SessionType;
  scheduled_date: string;
  assignee_id: string;
  status: SessionStatus;
  assignment_generation: number;
  opened_at: string;
  submitted_at: string | null;
  can_act: boolean;
  current_session_id: string | null;
  items: SessionItem[];
}

const SESSION_TYPE_LABELS: Record<SessionType, string> = {
  dropoff: '朝の送り',
  pickup: 'お迎え',
  nonpickup_evening: '今夜のチェック',
};

const STATUS_LABELS: Record<SessionStatus, string> = {
  open: '対応中',
  submitted: '完了',
  auto_closed: '完了（自動）',
  superseded: '担当変更により無効',
};

const ITEM_STATUS_LABELS: Record<SessionItem['status'], string> = {
  todo: '未着手',
  in_progress: '進行中',
  completed: '完了',
  skipped: '今回は不要',
  cancelled: '取消',
};

function isItemActive(item: SessionItem): boolean {
  return item.status === 'todo' || item.status === 'in_progress';
}

function useRoutineSession(sessionId: string | undefined) {
  const [session, setSession] = useState<RoutineSession | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!sessionId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const result = await callEdgeFunction<RoutineSession>(EDGE_FUNCTIONS.getRoutineSession, {
        session_id: sessionId,
      });
      setSession(result);
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '読み込みに失敗しました。');
    } finally {
      setLoading(false);
    }
  }, [sessionId]);

  useEffect(() => {
    load();
  }, [load]);

  return { session, loading, error, refresh: load };
}

export function CheckinPage() {
  const { sessionId } = useParams<{ sessionId: string }>();
  const { user } = useAuth();
  const { session, loading, error, refresh } = useRoutineSession(sessionId);
  const [busyItemId, setBusyItemId] = useState<string | null>(null);
  const [busyAll, setBusyAll] = useState(false);
  const [individualMode, setIndividualMode] = useState(false);
  const [reconciliationMessage, setReconciliationMessage] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  if (!sessionId) {
    return <div className="app-shell">セッションが指定されていません。</div>;
  }
  if (loading) {
    return <div className="app-shell">読み込み中…</div>;
  }
  if (error) {
    return (
      <div className="app-shell">
        <p role="alert" className="error-text">
          {error}
        </p>
      </div>
    );
  }
  if (!session) {
    return <div className="app-shell">セッションが見つかりません。</div>;
  }

  const activeItems = session.items.filter(isItemActive);
  const canAct = session.can_act && session.status === 'open';

  async function runItemAction(taskInstanceId: string, action: ItemAction) {
    setActionError(null);
    setBusyItemId(taskInstanceId);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.routineSessionItemAction, {
        operation_id: newOperationId(),
        session_id: sessionId,
        task_instance_id: taskInstanceId,
        action,
      });
      await refresh();
    } catch (err) {
      setActionError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。');
    } finally {
      setBusyItemId(null);
    }
  }

  async function runSubtaskAction(subtask: SubtaskRow) {
    setActionError(null);
    setBusyItemId(subtask.id);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.setSubtaskCompletion, {
        operation_id: newOperationId(),
        subtask_instance_id: subtask.id,
        completed: !subtask.is_completed,
        completion_actor: 'self',
      });
      await refresh();
    } catch (err) {
      setActionError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。');
    } finally {
      setBusyItemId(null);
    }
  }

  async function runReconciliation(responseKind: ReconciliationResponse) {
    setActionError(null);
    setBusyAll(true);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.reconcileRoutineSession, {
        operation_id: newOperationId(),
        session_id: sessionId,
        response_kind: responseKind,
      });
      setReconciliationMessage(
        responseKind === 'all_done'
          ? '完了として記録しました。気になる項目は履歴から訂正できます。'
          : responseKind === 'mostly_done'
            ? '「大体やった」と記録しました。項目は勝手に完了にしていません。'
            : '個別で答える入力に切り替えました。',
      );
      if (responseKind === 'individual') setIndividualMode(true);
      await refresh();
    } catch (err) {
      setActionError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。');
    } finally {
      setBusyAll(false);
    }
  }

  return (
    <div className="app-shell">
      <div className="today-header">
        <h1>
          {SESSION_TYPE_LABELS[session.session_type]} · {session.scheduled_date}
        </h1>
        <span className="task-item-meta">{STATUS_LABELS[session.status]}</span>
      </div>

      {session.status === 'superseded' && (
        <p role="alert" className="error-text">
          担当の変更によりこのチェックは無効になりました（読み取り専用）。
          {session.current_session_id && (
            <>
              {' '}
              <Link to={`/checkin/${session.current_session_id}`}>最新のチェックを見る</Link>
            </>
          )}
        </p>
      )}
      {!session.can_act && session.status === 'open' && (
        <p className="task-item-meta">このチェックは他の担当者のものです（閲覧のみ）。</p>
      )}
      {actionError && (
        <p role="alert" className="error-text">
          {actionError}
        </p>
      )}
      {reconciliationMessage && <p role="status" className="success-text">{reconciliationMessage}</p>}

      {canAct && activeItems.length > 0 && !individualMode && (
        <section className="card checkin-reconciliation" aria-labelledby="checkin-reconciliation-title">
          <p className="eyebrow">今夜の入力</p>
          <h2 id="checkin-reconciliation-title">今日はどうでしたか？</h2>
          <p className="empty-hint">細かな入力は例外があるときだけで大丈夫です。</p>
          <div className="checkin-reconciliation-actions">
            <button type="button" className="hero-primary" disabled={busyAll} onClick={() => runReconciliation('all_done')}>
              全部やった
            </button>
            <button type="button" className="secondary-button" disabled={busyAll} onClick={() => runReconciliation('mostly_done')}>
              大体やった
            </button>
            <button type="button" className="text-button" disabled={busyAll} onClick={() => runReconciliation('individual')}>
              個別で答える
            </button>
          </div>
        </section>
      )}

      {canAct && individualMode && (
        <p className="task-item-meta">個別入力中です。通常の完了を先に、例外は「その他」から選べます。</p>
      )}

      <ul className="handover-list">
        {session.items.map((item) => (
          <li key={item.task_instance_id} className="handover-item">
            <div>
              <p>{item.title}</p>
              <span className="task-item-meta">{ITEM_STATUS_LABELS[item.status]}</span>
              {item.completion_mode === 'subtasks' && item.subtasks.length > 0 && (
                <ul className="subtask-list subtask-checklist checkin-subtask-list">
                  {item.subtasks.map((st) => (
                    <li key={st.id}>
                      <button
                        type="button"
                        className="subtask-check-row"
                        disabled={!canAct || busyAll || busyItemId === st.id}
                        onClick={() => runSubtaskAction(st)}
                        aria-pressed={st.is_completed}
                      >
                        <span className={st.is_completed ? 'subtask-checkbox checked' : 'subtask-checkbox'} aria-hidden="true">
                          {st.is_completed ? '✓' : ''}
                        </span>
                        <span className={st.is_completed ? 'checked' : ''}>
                          {st.title}{!st.required && <small>（任意）</small>}
                        </span>
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </div>
            {canAct && isItemActive(item) && (
              <div className="checkin-item-actions">
                <button
                  type="button"
                  className="hero-primary"
                  disabled={busyItemId === item.task_instance_id || busyAll}
                  onClick={() => runItemAction(item.task_instance_id, 'complete')}
                >
                  完了
                </button>
                <details className="task-overflow">
                  <summary aria-label={`${item.title}のその他の結果`}>その他</summary>
                  <div>
                    <button
                      type="button"
                      disabled={busyItemId === item.task_instance_id || busyAll}
                      onClick={() => runItemAction(item.task_instance_id, 'partner_handled')}
                    >
                      相手が対応
                    </button>
                    <button
                      type="button"
                      className="danger-button"
                      disabled={busyItemId === item.task_instance_id || busyAll}
                      onClick={() => runItemAction(item.task_instance_id, 'skip')}
                    >
                      今回は不要
                    </button>
                  </div>
                </details>
              </div>
            )}
          </li>
        ))}
        {session.items.length === 0 && <li className="empty-hint">項目はありません。</li>}
      </ul>

      <Link className="text-button checkin-back-link" to="/">今日に戻る</Link>
      {!user && <p className="task-item-meta">ログイン情報を確認できません。</p>}
    </div>
  );
}
