import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';

interface ActiveSimulation {
  active: boolean;
  test_context_id?: string;
  revision?: number;
  simulated_role?: 'mama' | 'papa';
  operator_display_label?: string;
  simulated_display_label?: string;
}

interface SimulationAttempt {
  attempt_id: string;
  attempt_kind: string;
  state: string;
  revision: number;
  terms_revision: number;
  reply_due_at: string | null;
}

interface SimulationRequest {
  request_id: string;
  title: string;
  message: string | null;
  due_at: string | null;
  status: string;
  revision: number;
  direction: 'operator_to_simulated' | 'simulated_to_operator';
  requester_side: 'operator' | 'simulated';
  recipient_side: 'operator' | 'simulated';
  latest_attempt: SimulationAttempt | null;
  linked_task_id: string | null;
  created_at: string;
}

interface SimulationTask {
  task_id: string;
  request_id: string | null;
  title: string;
  status: string;
  revision: number;
  due_at: string | null;
  planned_assignee_side: 'operator' | 'simulated' | null;
  completed_at: string | null;
}

interface SimulationDelivery {
  id: string;
  semantic_recipient_side: 'operator' | 'simulated' | 'unknown';
  channel: string;
  delivery_mode: string;
  status: string;
  payload: Record<string, unknown>;
  created_at: string;
}

interface SimulationWorkspace {
  test_context_id: string;
  status: string;
  revision: number;
  label: string | null;
  simulated_role: 'mama' | 'papa';
  operator_display_label: string;
  simulated_display_label: string;
  requests: SimulationRequest[];
  tasks: SimulationTask[];
  deliveries: SimulationDelivery[];
  production_side_effects: false;
}

function errorMessage(error: unknown): string {
  if (error instanceof FamilyOpsApiError) return error.message;
  return error instanceof Error ? error.message : '操作に失敗しました。';
}

function sideLabel(side: 'operator' | 'simulated' | 'unknown', workspace: SimulationWorkspace): string {
  if (side === 'operator') return `本人（${workspace.operator_display_label}）`;
  if (side === 'simulated') return `相手役（${workspace.simulated_display_label}）`;
  return 'テスト相手';
}

function deliveryText(delivery: SimulationDelivery): string {
  const title = typeof delivery.payload.title === 'string' ? delivery.payload.title : '';
  const body = typeof delivery.payload.body === 'string' ? delivery.payload.body : '';
  if (title || body) return [title, body].filter(Boolean).join(' — ');
  return 'テスト通知を記録しました';
}

export function TestSimulation() {
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [active, setActive] = useState<ActiveSimulation | null>(null);
  const [workspace, setWorkspace] = useState<SimulationWorkspace | null>(null);
  const [simulatedRole, setSimulatedRole] = useState<'mama' | 'papa'>('mama');
  const [direction, setDirection] = useState<'operator_to_simulated' | 'simulated_to_operator'>('operator_to_simulated');
  const [title, setTitle] = useState('お迎えお願い');
  const [message, setMessage] = useState('今日はお迎えをお願いできますか？');
  const [dueAt, setDueAt] = useState('');

  const loadWorkspace = useCallback(async (testContextId: string) => {
    const result = await callEdgeFunction<SimulationWorkspace>(EDGE_FUNCTIONS.testSimulation, {
      action: 'workspace',
      test_context_id: testContextId,
    });
    setWorkspace(result);
    setActive({
      active: result.status === 'active',
      test_context_id: result.test_context_id,
      revision: result.revision,
      simulated_role: result.simulated_role,
      operator_display_label: result.operator_display_label,
      simulated_display_label: result.simulated_display_label,
    });
  }, []);

  const loadCurrent = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await callEdgeFunction<ActiveSimulation>(EDGE_FUNCTIONS.testSimulation, { action: 'current' });
      setActive(result);
      if (result.active && result.test_context_id) await loadWorkspace(result.test_context_id);
      else setWorkspace(null);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setLoading(false);
    }
  }, [loadWorkspace]);

  useEffect(() => { void loadCurrent(); }, [loadCurrent]);

  async function startSimulation() {
    setBusy(true);
    setError(null);
    try {
      const result = await callEdgeFunction<{ test_context_id: string }>(EDGE_FUNCTIONS.testSimulation, {
        action: 'open',
        operation_id: newOperationId(),
        simulated_role: simulatedRole,
        label: 'PWA 1人E2Eテスト',
      });
      await loadWorkspace(result.test_context_id);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  async function sendRequest(event: FormEvent) {
    event.preventDefault();
    if (!workspace) return;
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.testSimulation, {
        action: 'send_request',
        operation_id: newOperationId(),
        test_context_id: workspace.test_context_id,
        direction,
        title: title.trim(),
        message: message.trim(),
        due_at: dueAt ? new Date(dueAt).toISOString() : undefined,
      });
      await loadWorkspace(workspace.test_context_id);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  async function respond(request: SimulationRequest, responseAction: 'accept' | 'decline') {
    if (!workspace || !request.latest_attempt) return;
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.testSimulation, {
        action: 'respond_request',
        operation_id: newOperationId(),
        test_context_id: workspace.test_context_id,
        request_id: request.request_id,
        attempt_id: request.latest_attempt.attempt_id,
        response_action: responseAction,
        expected_revision: request.latest_attempt.revision,
        expected_terms_revision: request.latest_attempt.terms_revision,
      });
      await loadWorkspace(workspace.test_context_id);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  async function completeTask(task: SimulationTask) {
    if (!workspace) return;
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.testSimulation, {
        action: 'complete_task',
        operation_id: newOperationId(),
        test_context_id: workspace.test_context_id,
        task_id: task.task_id,
        expected_revision: task.revision,
      });
      await loadWorkspace(workspace.test_context_id);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  async function archiveSimulation() {
    if (!workspace) return;
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.testSimulation, {
        action: 'archive',
        operation_id: newOperationId(),
        test_context_id: workspace.test_context_id,
        expected_revision: workspace.revision,
      });
      setWorkspace(null);
      setActive({ active: false });
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  if (loading) return <main className="app-shell"><p>1人テストモードを確認中…</p></main>;

  return (
    <main className="app-shell test-simulation-page">
      <div className="test-mode-banner" role="status">
        <strong>🧪 TEST MODE</strong>
        <span>ここで作るお願い・タスク・通知はテスト専用です。家族・LINE・Googleには送られません。</span>
      </div>
      <div className="today-header">
        <div>
          <p className="eyebrow">DD10 · 1アカウントE2E</p>
          <h1>1人テストモード</h1>
        </div>
        <Link to="/settings">設定へ戻る</Link>
      </div>

      {error && <p className="error-text" role="alert">{error}</p>}

      {!active?.active || !workspace ? (
        <section className="card">
          <h2>相手役を作って試す</h2>
          <p>ログインは今のあなたのままです。相手役はテスト専用ActorRefとして作られ、実ユーザーにはなりません。</p>
          <label>
            相手役
            <select value={simulatedRole} onChange={(e) => setSimulatedRole(e.target.value as 'mama' | 'papa')}>
              <option value="mama">ママ役</option>
              <option value="papa">パパ役</option>
            </select>
          </label>
          <button type="button" onClick={startSimulation} disabled={busy}>
            {busy ? '開始中…' : 'テストを開始'}
          </button>
        </section>
      ) : (
        <>
          <section className="card test-mode-summary">
            <h2>テスト中</h2>
            <p><strong>本人:</strong> {workspace.operator_display_label}</p>
            <p><strong>相手役:</strong> {workspace.simulated_display_label}</p>
            <p className="empty-hint">本番副作用: なし / test_contextで完全分離</p>
          </section>

          <form className="card stack-form" onSubmit={sendRequest}>
            <h2>1. お願いを作る</h2>
            <label>
              向き
              <select value={direction} onChange={(e) => setDirection(e.target.value as typeof direction)}>
                <option value="operator_to_simulated">本人 → 相手役</option>
                <option value="simulated_to_operator">相手役 → 本人</option>
              </select>
            </label>
            <label>タイトル<input value={title} maxLength={160} onChange={(e) => setTitle(e.target.value)} required /></label>
            <label>メッセージ<textarea value={message} maxLength={2000} onChange={(e) => setMessage(e.target.value)} /></label>
            <label>期限（任意）<input type="datetime-local" value={dueAt} onChange={(e) => setDueAt(e.target.value)} /></label>
            <button type="submit" disabled={busy}>{busy ? '処理中…' : 'テストお願いを送る'}</button>
          </form>

          <section className="card">
            <h2>2. お願いに返事する</h2>
            {workspace.requests.length === 0 && <p className="empty-hint">まだお願いはありません。</p>}
            <ul className="request-list">
              {workspace.requests.map((request) => {
                const attempt = request.latest_attempt;
                const actionable = attempt && ['pending', 'checking'].includes(attempt.state);
                return (
                  <li key={request.request_id} className="request-item">
                    <div>
                      <strong>{request.title}</strong>
                      <p>{sideLabel(request.requester_side, workspace)} → {sideLabel(request.recipient_side, workspace)}</p>
                      {request.message && <p>{request.message}</p>}
                      <span className="task-item-meta">状態: {attempt?.state ?? request.status}</span>
                    </div>
                    {actionable && (
                      <div className="task-item-actions">
                        <button type="button" disabled={busy} onClick={() => respond(request, 'accept')}>引き受ける</button>
                        <button type="button" disabled={busy} onClick={() => respond(request, 'decline')}>断る</button>
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          </section>

          <section className="card">
            <h2>3. できたら完了する</h2>
            {workspace.tasks.length === 0 && <p className="empty-hint">お願いを引き受けると、ここに実行タスクが出ます。</p>}
            <ul className="task-list">
              {workspace.tasks.map((task) => (
                <li key={task.task_id} className="task-item">
                  <div>
                    <strong>{task.title}</strong>
                    <span className="task-item-meta"> · {task.status} · 担当: {task.planned_assignee_side ? sideLabel(task.planned_assignee_side, workspace) : '未定'}</span>
                  </div>
                  {['todo', 'in_progress'].includes(task.status) && task.planned_assignee_side && (
                    <button type="button" disabled={busy} onClick={() => completeTask(task)}>完了にする</button>
                  )}
                </li>
              ))}
            </ul>
          </section>

          <section className="card">
            <h2>テスト通知</h2>
            <p className="empty-hint">実LINEには送らず、テスト用outboxにだけ記録します。</p>
            {workspace.deliveries.length === 0 ? <p>まだありません。</p> : (
              <ul className="notification-list">
                {workspace.deliveries.map((delivery) => (
                  <li key={delivery.id}>
                    <strong>{sideLabel(delivery.semantic_recipient_side, workspace)}</strong>
                    <p>{deliveryText(delivery)}</p>
                  </li>
                ))}
              </ul>
            )}
          </section>

          <section className="card test-mode-danger-zone">
            <h2>テストを終了</h2>
            <p>終了するとこのテストはarchiveされます。本番データへ変換されることはありません。</p>
            <button type="button" className="text-button" disabled={busy} onClick={archiveSimulation}>テストを終了する</button>
          </section>
        </>
      )}
    </main>
  );
}
