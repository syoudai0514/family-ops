// Route: /checkin/:sessionId -> CheckinPage
import { useCallback, useEffect, useState } from 'react';
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom';
import { useAuth } from '../../app/AuthContext';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { useCurrentRoutineSessions, type CurrentRoutineSessionType } from './useCurrentRoutineSessions';

type SessionType = 'dropoff' | 'pickup' | 'nonpickup_evening';
type SessionStatus = 'open' | 'submitted' | 'auto_closed' | 'superseded';
type ItemAction = 'complete' | 'partner_handled' | 'skip' | 'failed' | 'cancelled' | 'rescheduled' | 'unknown';
type ReconciliationResponse = 'all_done' | 'mostly_done' | 'individual';
type TaskExpectation = 'required' | 'normal' | 'optional';

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
  outcome_reason?: 'could_not_do' | 'not_needed_this_occurrence' | 'expired_occurrence' | 'rescheduled' | 'unknown' | null;
  rescheduled_to?: string | null;
  expectation?: TaskExpectation;
  revision?: number;
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

interface ReconciliationResult {
  reconciliation_operation_id?: string;
  undo_available?: boolean;
}

const SESSION_TYPE_LABELS: Record<SessionType, string> = {
  dropoff: '朝の送り', pickup: 'お迎え', nonpickup_evening: '今夜のチェック',
};
const STATUS_LABELS: Record<SessionStatus, string> = {
  open: '対応中', submitted: '完了', auto_closed: '完了（自動）', superseded: '担当変更により無効',
};

export function previousIsoDate(isoDate: string): string {
  const [year, month, day] = isoDate.split('-').map(Number);
  const value = new Date(Date.UTC(year, month - 1, day));
  value.setUTCDate(value.getUTCDate() - 1);
  return value.toISOString().slice(0, 10);
}

export function countCheckinBulkScope(items: Array<{ expectation?: TaskExpectation }>): { eligibleCount: number; optionalCount: number } {
  let eligibleCount = 0;
  let optionalCount = 0;
  for (const item of items) {
    if ((item.expectation ?? 'normal') === 'optional') optionalCount += 1;
    else eligibleCount += 1;
  }
  return { eligibleCount, optionalCount };
}

function itemStatusLabel(item: SessionItem): string {
  if (item.status === 'completed') return '完了';
  if (item.status === 'cancelled') return '中止';
  if (item.status === 'skipped') {
    if (item.outcome_reason === 'could_not_do') return 'できなかった';
    if (item.outcome_reason === 'not_needed_this_occurrence') return '今回は不要';
    if (item.outcome_reason === 'rescheduled') return item.rescheduled_to ? `再予定: ${item.rescheduled_to}` : '再予定';
    if (item.outcome_reason === 'unknown') return '不明';
    if (item.outcome_reason === 'expired_occurrence') return '期限終了';
    return '例外';
  }
  return item.status === 'in_progress' ? '進行中' : '未着手';
}
function inputLabel(sessionType: SessionType): string {
  return sessionType === 'dropoff' ? '🌅 朝の入力' : sessionType === 'pickup' ? '🌆 お迎えの入力' : '🌙 今夜の入力';
}
function isItemActive(item: SessionItem): boolean { return item.status === 'todo' || item.status === 'in_progress'; }

function useRoutineSession(sessionId: string | undefined) {
  const [session, setSession] = useState<RoutineSession | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => {
    if (!sessionId) { setLoading(false); return; }
    setLoading(true); setError(null);
    try {
      setSession(await callEdgeFunction<RoutineSession>(EDGE_FUNCTIONS.getRoutineSession, { session_id: sessionId }));
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '読み込みに失敗しました。');
    } finally { setLoading(false); }
  }, [sessionId]);
  useEffect(() => { void load(); }, [load]);
  return { session, loading, error, refresh: load };
}

export function CheckinPage() {
  const { sessionId } = useParams<{ sessionId: string }>();
  const { user } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const currentInputs = useCurrentRoutineSessions(Boolean(user));
  const { session, loading, error, refresh } = useRoutineSession(sessionId);
  const [busyItemId, setBusyItemId] = useState<string | null>(null);
  const [busyAll, setBusyAll] = useState(false);
  const [individualMode, setIndividualMode] = useState(false);
  const [reconciliationMessage, setReconciliationMessage] = useState<string | null>(null);
  const [reconciliationOperationId, setReconciliationOperationId] = useState<string | null>(null);
  const [rescheduleDates, setRescheduleDates] = useState<Record<string, string>>({});
  const [actionError, setActionError] = useState<string | null>(null);

  if (!sessionId) return <div className="app-shell">セッションが指定されていません。</div>;
  if (loading) return <div className="app-shell">読み込み中…</div>;
  if (error) return <div className="app-shell"><p role="alert" className="error-text">{error}</p></div>;
  if (!session) return <div className="app-shell">セッションが見つかりません。</div>;

  const activeItems = session.items.filter(isItemActive);
  const { eligibleCount, optionalCount } = countCheckinBulkScope(activeItems);
  const canAct = session.can_act && session.status === 'open';
  // A bulk receipt is the correction authority. Optional rows can keep the
  // routine session open, so do not incorrectly hide immediate correction/undo
  // merely because the session itself has not become submitted.
  const canCorrectBulk = Boolean(reconciliationOperationId);
  const morningInput = currentInputs.sessions.find((candidate) => candidate.can_act && candidate.session_type === 'dropoff') ?? null;
  const eveningInput = currentInputs.sessions.find((candidate) => candidate.can_act && candidate.session_type === 'nonpickup_evening') ?? null;
  const originState = { originPath: location.pathname, originScrollY: window.scrollY };

  function goToCurrentInput(type: CurrentRoutineSessionType) {
    const target = currentInputs.sessions.find((candidate) => candidate.can_act && candidate.session_type === type);
    if (target) navigate(`/checkin/${target.id}`, { replace: target.id === sessionId });
  }

  async function runItemAction(taskInstanceId: string, action: ItemAction) {
    setActionError(null); setBusyItemId(taskInstanceId);
    try {
      const rescheduledTo = action === 'rescheduled' ? rescheduleDates[taskInstanceId] : null;
      if (action === 'rescheduled' && !rescheduledTo) {
        setActionError('再予定の日を選んでください。'); return;
      }
      await callEdgeFunction(EDGE_FUNCTIONS.routineSessionItemAction, {
        operation_id: newOperationId(), session_id: sessionId, task_instance_id: taskInstanceId, action,
        rescheduled_to: rescheduledTo,
        reconciliation_operation_id: canCorrectBulk ? reconciliationOperationId : null,
      });
      setReconciliationMessage(canCorrectBulk ? '一括完了の例外を修正しました。' : null);
      await refresh();
    } catch (err) {
      setActionError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。');
    } finally { setBusyItemId(null); }
  }

  async function runSubtaskAction(subtask: SubtaskRow) {
    setActionError(null); setBusyItemId(subtask.id);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.setSubtaskCompletion, {
        operation_id: newOperationId(), subtask_instance_id: subtask.id, completed: !subtask.is_completed, completion_actor: 'self',
      });
      await refresh();
    } catch (err) { setActionError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。'); }
    finally { setBusyItemId(null); }
  }

  async function runReconciliation(responseKind: ReconciliationResponse) {
    setActionError(null); setBusyAll(true);
    try {
      const result = await callEdgeFunction<ReconciliationResult>(EDGE_FUNCTIONS.reconcileRoutineSession, {
        operation_id: newOperationId(), session_id: sessionId, response_kind: responseKind,
      });
      if (responseKind === 'all_done' && result.reconciliation_operation_id) {
        setReconciliationOperationId(result.reconciliation_operation_id);
        setReconciliationMessage('完了として記録しました。直後なら例外修正・元に戻すができます。');
      } else if (responseKind === 'mostly_done') {
        setReconciliationMessage('「大体やった」と記録しました。項目は勝手に完了にしていません。');
      } else {
        setReconciliationMessage('個別に記録する入力へ切り替えました。'); setIndividualMode(true);
      }
      await refresh();
    } catch (err) { setActionError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。'); }
    finally { setBusyAll(false); }
  }

  async function undoReconciliation() {
    if (!reconciliationOperationId) return;
    setBusyAll(true); setActionError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.reconcileRoutineSession, {
        action: 'undo', operation_id: newOperationId(), target_operation_id: reconciliationOperationId,
      });
      setReconciliationOperationId(null); setIndividualMode(false);
      setReconciliationMessage('一括完了を元に戻しました。');
      await refresh();
    } catch (err) { setActionError(err instanceof FamilyOpsApiError ? err.message : '元に戻せませんでした。最新の状態を確認してください。'); }
    finally { setBusyAll(false); }
  }

  return <div className="app-shell">
    <nav className="filter-chips" aria-label="チェックイン対象の切り替え">
      <button type="button" className={session.session_type === 'nonpickup_evening' ? 'active' : ''} aria-pressed={session.session_type === 'nonpickup_evening'} disabled={!eveningInput || currentInputs.loading} onClick={() => goToCurrentInput('nonpickup_evening')}>今夜</button>
      <button type="button" className={session.session_type === 'dropoff' ? 'active' : ''} aria-pressed={session.session_type === 'dropoff'} disabled={!morningInput || currentInputs.loading} onClick={() => goToCurrentInput('dropoff')}>朝の未入力{morningInput ? ` ${morningInput.remaining_count}` : ''}</button>
      <button type="button" onClick={() => navigate('/history', { state: { correctionDate: previousIsoDate(session.scheduled_date), ...originState } })}>昨日分修正</button>
      <button type="button" onClick={() => navigate('/actuals/new', { state: originState })}>予定外実績</button>
    </nav>
    {currentInputs.error && <p role="status" className="empty-hint">{currentInputs.error}</p>}
    <div className="today-header"><h1>{SESSION_TYPE_LABELS[session.session_type]} · {session.scheduled_date}</h1><span className="task-item-meta">{STATUS_LABELS[session.status]}</span></div>
    {session.status === 'superseded' && <p role="alert" className="error-text">担当の変更によりこのチェックは無効になりました（読み取り専用）。{session.current_session_id && <> <Link to={`/checkin/${session.current_session_id}`}>最新のチェックを見る</Link></>}</p>}
    {!session.can_act && session.status === 'open' && <p className="task-item-meta">このチェックは他の担当者のものです（閲覧のみ）。</p>}
    {actionError && <p role="alert" className="error-text">{actionError}</p>}
    {reconciliationMessage && <p role="status" className="success-text">{reconciliationMessage}</p>}

    {canCorrectBulk && <section className="card checkin-reconciliation" aria-label="一括完了の直後操作">
      <h2>一括完了を記録しました</h2>
      <p className="empty-hint">この操作で変更した項目だけを訂正できます。後から別の更新が入った場合、元に戻す操作は安全のため止まります。</p>
      <div className="checkin-reconciliation-actions">
        <button type="button" className="secondary-button" disabled={busyAll} onClick={() => setIndividualMode(true)}>例外を修正</button>
        <button type="button" className="text-button" disabled={busyAll} onClick={undoReconciliation}>元に戻す</button>
      </div>
    </section>}

    {canAct && activeItems.length > 0 && !individualMode && <section className="card checkin-reconciliation" aria-labelledby="checkin-reconciliation-title">
      <p className="eyebrow">{inputLabel(session.session_type)}</p><h2 id="checkin-reconciliation-title">今日はどうでしたか？</h2>
      <div className="checkin-scope" aria-label="一括操作の対象">
        <strong>この操作の対象: 必須/通常 {eligibleCount}件</strong>
        <span className="task-item-meta">余力 {optionalCount}件は対象外</span>
      </div>
      <p className="empty-hint">細かな入力は例外があるときだけで大丈夫です。「大体やった」では未入力項目や子項目を勝手に完了にしません。</p>
      <div className="checkin-reconciliation-actions">
        <button type="button" className="hero-primary" disabled={busyAll || eligibleCount === 0} onClick={() => runReconciliation('all_done')}>全部やった</button>
        <button type="button" className="secondary-button" disabled={busyAll || eligibleCount === 0} onClick={() => runReconciliation('mostly_done')}>大体やった</button>
        <button type="button" className="text-button" disabled={busyAll} onClick={() => runReconciliation('individual')}>個別に記録</button>
      </div>
    </section>}

    {(canAct || canCorrectBulk) && individualMode && <p className="task-item-meta">個別入力中です。完了・相手対応・できなかった・今回不要・中止・再予定・不明を区別して残せます。</p>}

    <ul className="handover-list">
      {session.items.map((item) => {
        const canEditItem = (canAct && isItemActive(item)) || (canCorrectBulk && individualMode && item.status === 'completed');
        return <li key={item.task_instance_id} className="handover-item">
          <div><p>{item.title}</p><span className="task-item-meta">{itemStatusLabel(item)}</span>
            {item.completion_mode === 'subtasks' && item.subtasks.length > 0 && <ul className="subtask-list subtask-checklist checkin-subtask-list">{item.subtasks.map((st) => <li key={st.id}><button type="button" className="subtask-check-row" disabled={!canAct || busyAll || busyItemId === st.id} onClick={() => runSubtaskAction(st)} aria-pressed={st.is_completed}><span className={st.is_completed ? 'subtask-checkbox checked' : 'subtask-checkbox'} aria-hidden="true">{st.is_completed ? '✓' : ''}</span><span className={st.is_completed ? 'checked' : ''}>{st.title}{!st.required && <small>（任意）</small>}</span></button></li>)}</ul>}
          </div>
          {canEditItem && <div className="checkin-item-actions">
            <button type="button" className="hero-primary" disabled={busyItemId === item.task_instance_id || busyAll} onClick={() => runItemAction(item.task_instance_id, 'complete')}>完了</button>
            <details className="task-overflow"><summary aria-label={`${item.title}のその他の結果`}>その他の結果</summary><div>
              <button type="button" disabled={busyItemId === item.task_instance_id || busyAll} onClick={() => runItemAction(item.task_instance_id, 'partner_handled')}>相手が対応</button>
              <button type="button" disabled={busyItemId === item.task_instance_id || busyAll} onClick={() => runItemAction(item.task_instance_id, 'failed')}>できなかった</button>
              <button type="button" disabled={busyItemId === item.task_instance_id || busyAll} onClick={() => runItemAction(item.task_instance_id, 'skip')}>今回は不要</button>
              <button type="button" disabled={busyItemId === item.task_instance_id || busyAll} onClick={() => runItemAction(item.task_instance_id, 'cancelled')}>中止</button>
              <label>再予定日<input type="date" aria-label={`${item.title}の再予定日`} value={rescheduleDates[item.task_instance_id] ?? ''} onChange={(event) => setRescheduleDates((current) => ({ ...current, [item.task_instance_id]: event.target.value }))} /></label>
              <button type="button" disabled={busyItemId === item.task_instance_id || busyAll || !rescheduleDates[item.task_instance_id]} onClick={() => runItemAction(item.task_instance_id, 'rescheduled')}>再予定</button>
              <button type="button" disabled={busyItemId === item.task_instance_id || busyAll} onClick={() => runItemAction(item.task_instance_id, 'unknown')}>不明</button>
            </div></details>
          </div>}
        </li>;
      })}
      {session.items.length === 0 && <li className="empty-hint">項目はありません。</li>}
    </ul>
    <button type="button" className="text-button checkin-back-link" onClick={() => navigate(-1)}>戻る</button>
    {!user && <p className="task-item-meta">ログイン情報を確認できません。</p>}
  </div>;
}
