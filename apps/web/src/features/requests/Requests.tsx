import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from '../../app/AuthContext';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { formatDateTimeJa } from '../../lib/date';
import type { PendingAction, RequestRow } from '../../lib/types';

interface RequestAttempt {
  id: string;
  request_id: string;
  state: 'pending' | 'checking' | 'consulting' | 'awaiting_confirmation' | 'accepted' | 'declined' | 'expired' | 'cancelled';
  revision: number;
  terms_revision: number;
  terms: Record<string, unknown> | null;
  reply_due_at?: string | null;
}

export type RequestBucket = 'active' | 'expired' | 'history';

export function requestBucket(status: string, dueAt: string | null | undefined, nowMs = Date.now()): RequestBucket {
  if (status === 'expired') return 'expired';
  if (['accepted', 'completed', 'cancelled', 'declined'].includes(status)) return 'history';
  if (dueAt && new Date(dueAt).getTime() <= nowMs) return 'expired';
  return 'active';
}

export function responseDeadline(attempt?: RequestAttempt): string | null {
  return attempt?.reply_due_at ?? null;
}

function useRequests(householdId: string | null) {
  const [requests, setRequests] = useState<RequestRow[]>([]);
  const [attempts, setAttempts] = useState<Map<string, RequestAttempt>>(new Map());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!householdId) {
      setLoading(false);
      return;
    }
    setError(null);
    const { data, error: fetchError } = await supabase
      .from('requests')
      .select('*')
      .eq('household_id', householdId)
      .order('due_at', { ascending: true, nullsFirst: false });
    if (fetchError) setError(fetchError.message);
    else {
      const rows = (data ?? []) as RequestRow[];
      const taskIds = rows.map((row) => row.linked_task_instance_id).filter((id): id is string => Boolean(id));
      const requestIds = rows.map((row) => row.id);
      if (requestIds.length > 0) {
        const { data: attemptRows, error: attemptError } = await supabase
          .from('request_attempts').select('id, request_id, state, revision, terms_revision, terms, reply_due_at')
          .in('request_id', requestIds).is('test_context_id', null)
          .order('created_at', { ascending: false });
        if (attemptError) setError(attemptError.message);
        else {
          const latest = new Map<string, RequestAttempt>();
          for (const attempt of (attemptRows ?? []) as RequestAttempt[]) {
            if (!latest.has(attempt.request_id)) latest.set(attempt.request_id, attempt);
          }
          setAttempts(latest);
        }
      } else setAttempts(new Map());
      if (taskIds.length > 0) {
        const { data: tasks, error: taskError } = await supabase
          .from('task_instances').select('id, revision, title, due_at').in('id', taskIds);
        if (taskError) setError(taskError.message);
        const byId = new Map((tasks ?? []).map((task) => [task.id, task]));
        setRequests(rows.map((row) => {
          const task = row.linked_task_instance_id ? byId.get(row.linked_task_instance_id) : undefined;
          return task ? { ...row, linked_task_revision: task.revision, linked_task_title: task.title, linked_task_due_at: task.due_at } : row;
        }));
      } else setRequests(rows);
    }
    setLoading(false);
  }, [householdId]);

  useEffect(() => { void load(); }, [load]);
  return { requests, attempts, loading, error, refresh: load };
}

export function Requests() {
  const { user } = useAuth();
  const { household, partner } = useHousehold();
  const { requests, attempts, loading, error, refresh } = useRequests(household?.id ?? null);
  const location = useLocation();
  const navigate = useNavigate();
  const restoreScrollY = typeof (location.state as { restoreScrollY?: unknown } | null)?.restoreScrollY === 'number'
    ? Number((location.state as { restoreScrollY: number }).restoreScrollY) : null;
  const pendingActionRawText = typeof (location.state as { pendingActionRawText?: unknown } | null)?.pendingActionRawText === 'string'
    ? (location.state as { pendingActionRawText: string }).pendingActionRawText
    : '';
  const pendingId = new URLSearchParams(location.search).get('pending');
  const otherResponseRequestId = new URLSearchParams(location.search).get('response') === 'other'
    ? new URLSearchParams(location.search).get('request') : null;
  const [pendingAction, setPendingAction] = useState<PendingAction | null>(null);
  const [pendingLoadError, setPendingLoadError] = useState<string | null>(null);
  const [showForm, setShowForm] = useState(() => Boolean(pendingId) || new URLSearchParams(location.search).has('date') || Boolean(pendingActionRawText));
  const [bucketFilter, setBucketFilter] = useState<RequestBucket>(() => {
    const raw = new URLSearchParams(location.search).get('bucket');
    return raw === 'expired' || raw === 'history' ? raw : 'active';
  });
  const restoredRef = useRef(false);
  const incoming = requests.filter((r) => r.recipient_id === user?.id);
  const outgoing = requests.filter((r) => r.requester_id === user?.id);
  const bucketedIncoming = incoming.filter((r) => requestBucket(attempts.get(r.id)?.state ?? r.status, responseDeadline(attempts.get(r.id))) === bucketFilter);
  const bucketedOutgoing = outgoing.filter((r) => requestBucket(attempts.get(r.id)?.state ?? r.status, responseDeadline(attempts.get(r.id))) === bucketFilter);
  const counts = useMemo(() => (['active', 'expired', 'history'] as RequestBucket[]).reduce<Record<RequestBucket, number>>((acc, bucket) => {
    acc[bucket] = requests.filter((r) => requestBucket(attempts.get(r.id)?.state ?? r.status, responseDeadline(attempts.get(r.id))) === bucket).length;
    return acc;
  }, { active: 0, expired: 0, history: 0 }), [requests, attempts]);
  const rowRefresh = useCallback(async () => {
    const scrollY = window.scrollY;
    await refresh();
    requestAnimationFrame(() => window.scrollTo({ top: scrollY, behavior: 'auto' }));
  }, [refresh]);

  useEffect(() => {
    if (restoredRef.current || restoreScrollY == null) return;
    restoredRef.current = true;
    requestAnimationFrame(() => window.scrollTo({ top: restoreScrollY, behavior: 'auto' }));
  }, [restoreScrollY]);

  useEffect(() => {
    const params = new URLSearchParams(location.search);
    params.set('bucket', bucketFilter);
    navigate(`${location.pathname}?${params.toString()}`, { replace: true, state: location.state });
  }, [bucketFilter, location.pathname, location.search, location.state, navigate]);

  useEffect(() => {
    let cancelled = false;
    if (!pendingId) { setPendingAction(null); return () => { cancelled = true; }; }
    void (async () => {
      try {
        const actions = await callEdgeFunction<PendingAction[]>(EDGE_FUNCTIONS.listPendingActions, {});
        const found = actions.find((action) => action.id === pendingId && action.action_type === 'assignment_change_request');
        if (!found) throw new Error('この下書きは見つからないか、すでに処理済みです。');
        if (!cancelled) setPendingAction(found);
      } catch (err) {
        if (!cancelled) setPendingLoadError(err instanceof FamilyOpsApiError ? err.message : err instanceof Error ? err.message : 'LINEの下書きを開けませんでした。');
      }
    })();
    return () => { cancelled = true; };
  }, [pendingId]);

  function clearPrivatePrefill() {
    const params = new URLSearchParams(location.search);
    params.delete('pending');
    const search = params.toString();
    navigate(`${location.pathname}${search ? `?${search}` : ''}`, { replace: true, state: null });
  }

  if (loading) return <div className="app-shell">読み込み中…</div>;

  return (
    <div className="app-shell">
      <div className="today-header">
        <h1>お願い</h1>
        {partner && <button type="button" onClick={() => { setShowForm((v) => !v); if (showForm) clearPrivatePrefill(); }}>{showForm ? '閉じる' : '+ お願いを送る'}</button>}
      </div>
      <div className="request-bucket-tabs" role="tablist" aria-label="お願いの状態">
        <button type="button" className={bucketFilter === 'active' ? 'active' : 'secondary-button'} onClick={() => setBucketFilter('active')}>対応中 {counts.active}</button>
        <button type="button" className={bucketFilter === 'expired' ? 'active' : 'secondary-button'} onClick={() => setBucketFilter('expired')}>期限切れ {counts.expired}</button>
        <button type="button" className={bucketFilter === 'history' ? 'active' : 'secondary-button'} onClick={() => setBucketFilter('history')}>履歴 {counts.history}</button>
      </div>
      {error && <section className="card state-card" role="alert"><b>お願いを読み込めませんでした</b><p>{error}</p><button type="button" onClick={() => void refresh()}>再読み込み</button></section>}
      {pendingLoadError && <p role="alert" className="error-text">{pendingLoadError}</p>}
      {showForm && partner && <SendRequestForm recipientId={partner.user_id} initialRawMessage={String(pendingAction?.normalized_payload.raw_text ?? pendingActionRawText)} initialMessage={String(pendingAction?.normalized_payload.shared_message ?? '')} initialTitle={String(pendingAction?.normalized_payload.title ?? '')} initialDueDate={pendingAction ? toDateTimeLocal(pendingAction.normalized_payload.due_at) : ''} pendingActionId={pendingAction?.id ?? null} onSent={() => { setShowForm(false); clearPrivatePrefill(); void rowRefresh(); }} />}

      <section className="card">
        <h2>受け取ったお願い</h2>
        {bucketedIncoming.length === 0 ? <p className="empty-hint">この状態のお願いはありません。</p> : <ul className="request-list">{bucketedIncoming.map((r) => <IncomingRequestRow key={r.id} request={r} attempt={attempts.get(r.id)} onChanged={rowRefresh} initialShowOther={r.id === otherResponseRequestId} />)}</ul>}
      </section>
      <section className="card">
        <h2>送ったお願い</h2>
        {bucketedOutgoing.length === 0 ? <p className="empty-hint">この状態のお願いはありません。</p> : <ul className="request-list">{bucketedOutgoing.map((r) => <OutgoingRequestRow key={r.id} request={r} attempt={attempts.get(r.id)} onChanged={rowRefresh} />)}</ul>}
      </section>
    </div>
  );
}

function statusLabel(status: RequestRow['status']): string {
  switch (status) { case 'pending': return '保留中'; case 'accepted': return '引き受け済み'; case 'declined': return '難しい'; case 'completed': return '完了'; case 'cancelled': return 'キャンセル済み'; default: return status; }
}

function IncomingRequestRow({ request, attempt, onChanged, initialShowOther = false }: { request: RequestRow; attempt?: RequestAttempt; onChanged: () => Promise<void> | void; initialShowOther?: boolean }) {
  const [busy, setBusy] = useState(false); const [error, setError] = useState<string | null>(null); const [showOther, setShowOther] = useState(initialShowOther);
  async function respond(kind: 'accept' | 'decline' | 'checking' | 'consult') {
    if (!attempt) { setError('このお願いは最新状態に更新してください。'); return; }
    setBusy(true); setError(null);
    try {
      const functionName = kind === 'checking' || kind === 'consult' ? EDGE_FUNCTIONS.respondRequest : kind === 'accept' && request.assignment_task_instance_id ? EDGE_FUNCTIONS.acceptAssignmentChangeRequest : kind === 'accept' ? EDGE_FUNCTIONS.acceptRequest : EDGE_FUNCTIONS.declineRequest;
      const result = await callEdgeFunction<{ reproposal_required?: boolean }>(functionName, { operation_id: newOperationId(), request_id: request.id, attempt_id: attempt.id, expected_revision: attempt.revision, expected_terms_revision: attempt.terms_revision, ...(kind === 'checking' || kind === 'consult' ? { response_action: kind } : {}) });
      if (result.reproposal_required) setError('この依頼は期限切れです。新しい担当変更のお願いを作成してください。');
      await onChanged();
    } catch (err) { setError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。最新状態を読み直してください。'); } finally { setBusy(false); }
  }
  async function negotiate(action: 'checking' | 'consult' | 'edit_terms' | 'confirm_terms' | 'decline', terms?: Record<string, unknown>) {
    if (!attempt) { setError('このお願いは最新状態に更新してください。'); return; }
    setBusy(true); setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.negotiateRequest, { operation_id: newOperationId(), request_id: request.id, attempt_id: attempt.id, action, terms, expected_revision: attempt.revision, expected_terms_revision: attempt.terms_revision });
      await onChanged();
    } catch (err) { setError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。最新状態を読み直してください。'); } finally { setBusy(false); }
  }
  const replyDueAt = responseDeadline(attempt);
  return <li className="request-item"><div><strong>{request.shared_title}</strong> — {request.assignment_task_instance_id ? `${request.assignment_scope === 'this_week' ? '今週だけ' : '今回だけ'}の担当変更` : statusLabel(request.status)}{request.shared_message && <p>{request.shared_message}</p>}{replyDueAt && <span className="task-item-meta">返事期限: {formatDateTimeJa(replyDueAt)}</span>}{request.due_at && <span className="task-item-meta">作業期限: {formatDateTimeJa(request.due_at)}</span>}</div>{attempt && requestBucket(attempt.state, responseDeadline(attempt)) === 'active' && attempt.state !== 'consulting' && attempt.state !== 'awaiting_confirmation' && <div className="task-item-actions"><button type="button" disabled={busy} onClick={() => respond('accept')}>やる</button><button type="button" disabled={busy} onClick={() => respond('decline')}>難しい</button><button type="button" className="text-button" disabled={busy} onClick={() => setShowOther((value) => !value)}>その他の返答</button></div>}{attempt && requestBucket(attempt.state, responseDeadline(attempt)) === 'active' && showOther && <div className="request-other-actions"><button type="button" className="secondary-button" disabled={busy} onClick={() => negotiate('checking')}>確認してみる</button><CommentedDecline busy={busy} onSubmit={(comment) => negotiate('decline', { comment })} /><button type="button" className="secondary-button" disabled={busy} onClick={() => negotiate('consult')}>相談する</button><p className="task-item-meta">相談を選んでも担当は変わりません。条件を確認して二人が同じ内容に同意してから確定します。</p></div>}{attempt && requestBucket(attempt.state, responseDeadline(attempt)) === 'active' && ['consulting', 'awaiting_confirmation'].includes(attempt.state) && <ConsultationTerms key={attempt.terms_revision} attempt={attempt} busy={busy} onAction={negotiate} />}{error && <p role="alert" className="error-text">{error}</p>}</li>;
}

function CommentedDecline({ busy, onSubmit }: { busy: boolean; onSubmit: (comment: string) => void }) { const [comment, setComment] = useState(''); return <div className="request-comment-row"><input aria-label="難しい理由（任意）" value={comment} onChange={(event) => setComment(event.target.value)} placeholder="コメント付きで難しい" /><button type="button" className="secondary-button" disabled={busy} onClick={() => onSubmit(comment)}>コメント付きで難しい</button></div>; }
function ConsultationTerms({ attempt, busy, onAction }: { attempt: RequestAttempt; busy: boolean; onAction: (action: 'edit_terms' | 'confirm_terms', terms?: Record<string, unknown>) => void }) { const [candidate, setCandidate] = useState(typeof attempt.terms?.candidate === 'string' ? attempt.terms.candidate : ''); return <div className="request-other-actions" aria-label="相談の条件"><p><strong>相談中</strong> — 担当はまだ変わりません。二人が同じ条件を確認してから確定します。</p><input aria-label="合意する条件" value={candidate} onChange={(event) => setCandidate(event.target.value)} placeholder="例：明日は私、金曜は交代" /><button type="button" className="secondary-button" disabled={busy || !candidate.trim()} onClick={() => onAction('edit_terms', { ...attempt.terms, candidate: candidate.trim() })}>この条件を提案</button><button type="button" disabled={busy || candidate.trim() !== (typeof attempt.terms?.candidate === 'string' ? attempt.terms.candidate : '')} onClick={() => onAction('confirm_terms')}>この条件で確認する</button><p className="task-item-meta">現在: {attempt.state === 'awaiting_confirmation' ? '相手の確認待ち' : '条件の入力待ち'}（条件版 {attempt.terms_revision}）</p></div>; }

export function OutgoingRequestRow({ request, attempt, onChanged }: { request: RequestRow; attempt?: RequestAttempt; onChanged: () => Promise<void> | void }) {
  const [busy, setBusy] = useState(false); const [error, setError] = useState<string | null>(null);
  async function cancel() { if (!attempt) { setError('このお願いは最新状態に更新してください。'); return; } setBusy(true); setError(null); try { await callEdgeFunction(EDGE_FUNCTIONS.cancelRequest, { operation_id: newOperationId(), request_id: request.id, attempt_id: attempt.id, expected_revision: attempt.revision, expected_terms_revision: attempt.terms_revision }); await onChanged(); } catch (err) { if (err instanceof FamilyOpsApiError && err.code === 'REQUEST_CANCEL_NOT_ALLOWED') setError('すでに引き受けられているため、キャンセルできません。'); else setError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。最新状態を読み直してください。'); } finally { setBusy(false); } }
  async function negotiate(action: 'edit_terms' | 'confirm_terms', terms?: Record<string, unknown>) {
    if (!attempt) return;
    setBusy(true); setError(null);
    try {
      const result = await callEdgeFunction<{ reproposal_required?: boolean }>(EDGE_FUNCTIONS.negotiateRequest, {
        operation_id: newOperationId(), request_id: request.id, attempt_id: attempt.id,
        action, terms, expected_revision: attempt.revision, expected_terms_revision: attempt.terms_revision,
      });
      if (result.reproposal_required) setError('返事期限を過ぎています。新しいお願いとして再提案してください。');
      await onChanged();
    } catch (err) { setError(err instanceof FamilyOpsApiError ? err.message : '条件を確認できませんでした。最新状態を確認してください。'); }
    finally { setBusy(false); }
  }
  const replyDueAt = responseDeadline(attempt);
  return <li className="request-item"><div><strong>{request.shared_title}</strong> — {statusLabel(request.status)}{request.shared_message && <p>{request.shared_message}</p>}{replyDueAt && <span className="task-item-meta">返事期限: {formatDateTimeJa(replyDueAt)}</span>}{request.due_at && <span className="task-item-meta">作業期限: {formatDateTimeJa(request.due_at)}</span>}</div>{attempt && requestBucket(attempt.state, responseDeadline(attempt)) === 'active' && <div className="task-item-actions"><button type="button" disabled={busy} onClick={cancel}>キャンセル</button></div>}{attempt && requestBucket(attempt.state, responseDeadline(attempt)) === 'active' && ['consulting', 'awaiting_confirmation'].includes(attempt.state) && <ConsultationTerms key={attempt.terms_revision} attempt={attempt} busy={busy} onAction={negotiate} />}{request.status === 'accepted' && <AcceptedRequestFollowup request={request} onChanged={onChanged} />}{error && <p role="alert" className="error-text">{error}</p>}</li>;
}

function AcceptedRequestFollowup({ request, onChanged }: { request: RequestRow; onChanged: () => Promise<void> | void }) {
  const [mode, setMode] = useState<'change' | 'cancel' | null>(null); const [title, setTitle] = useState(request.linked_task_title ?? request.shared_title); const [replyDueAt, setReplyDueAt] = useState(''); const [busy, setBusy] = useState(false); const [error, setError] = useState<string | null>(null); const canPropose = typeof request.revision === 'number' && typeof request.linked_task_revision === 'number';
  async function submit() { if (!mode || !canPropose) return; if (mode === 'change' && !title.trim()) { setError('変更後の内容を入力してください。'); return; } setBusy(true); setError(null); try { await callEdgeFunction(EDGE_FUNCTIONS.startRequestFollowup, { operation_id: newOperationId(), request_id: request.id, attempt_kind: mode, task_patch: mode === 'change' ? { title: title.trim() } : undefined, reply_due_at: replyDueAt ? new Date(replyDueAt).toISOString() : undefined, expected_request_revision: request.revision, expected_task_revision: request.linked_task_revision }); setMode(null); await onChanged(); } catch (err) { setError(err instanceof FamilyOpsApiError ? err.message : '提案を送れませんでした。最新の状態を確認してください。'); } finally { setBusy(false); } }
  if (!request.linked_task_instance_id) return null;
  return <div className="request-followup">{!mode ? <div className="task-item-actions"><button type="button" className="secondary-button" disabled={!canPropose} onClick={() => setMode('change')}>変更を相談</button><button type="button" className="text-button" disabled={!canPropose} onClick={() => setMode('cancel')}>取消を相談</button></div> : <div className="stack-form request-followup-form"><p className="task-item-meta">{mode === 'change' ? '変更案を二人で確認してから反映します。' : '取消は相手の確認後にだけ反映します。'}</p>{mode === 'change' && <label>変更後の内容<input value={title} onChange={(event) => setTitle(event.target.value)} /></label>}<label>返事がほしい期限（任意）<input type="datetime-local" value={replyDueAt} onChange={(event) => setReplyDueAt(event.target.value)} /></label><div className="task-item-actions"><button type="button" disabled={busy} onClick={() => void submit()}>{busy ? '送信中…' : '確認をお願いする'}</button><button type="button" className="text-button" disabled={busy} onClick={() => setMode(null)}>やめる</button></div></div>}{!canPropose && <p className="task-item-meta">このお願いは最新情報を読み直してから変更・取消できます。</p>}{error && <p role="alert" className="error-text">{error}</p>}</div>;
}

function toDateTimeLocal(value: unknown): string { if (typeof value !== 'string' || !value) return ''; const date = new Date(value); if (Number.isNaN(date.getTime())) return ''; const parts = new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Tokyo', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(date).reduce<Record<string, string>>((result, part) => ({ ...result, [part.type]: part.value }), {}); return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}`; }

function SendRequestForm({ recipientId, initialRawMessage = '', initialMessage = '', initialTitle = '', initialDueDate = '', pendingActionId = null, onSent }: { recipientId: string; initialRawMessage?: string; initialMessage?: string; initialTitle?: string; initialDueDate?: string; pendingActionId?: string | null; onSent: () => void }) {
  const [title, setTitle] = useState(initialTitle); const [rawMessage, setRawMessage] = useState(initialRawMessage); const [message, setMessage] = useState(initialMessage); const [replyDueDate, setReplyDueDate] = useState(''); const [dueDate, setDueDate] = useState(initialDueDate); const [submitting, setSubmitting] = useState(false); const [rewriting, setRewriting] = useState(false); const [rawInputId, setRawInputId] = useState<string | null>(null); const [previewing, setPreviewing] = useState(false); const [error, setError] = useState<string | null>(null);
  async function rewriteMessageWithAi() { const rawText = rawMessage.trim(); if (!rawText) { setError('言い換えたいメッセージを入力してください。'); return; } setError(null); setRewriting(true); try { const proposal = await callEdgeFunction<{ raw_input_id: string; proposed_text: string }>(EDGE_FUNCTIONS.proposeAiDraft, { operation_id: newOperationId(), raw_text: rawText, target_type: 'request' }); setMessage(proposal.proposed_text); setRawInputId(proposal.raw_input_id); } catch (err) { setError(err instanceof FamilyOpsApiError ? err.message : 'AIによる言い換えに失敗しました。'); } finally { setRewriting(false); } }
  async function handleSubmit(event: FormEvent) { event.preventDefault(); setError(null); setSubmitting(true); try { if (!message.trim()) { setError('相手へ共有する文面を入力してください。'); return; } const payload = { operation_id: newOperationId(), recipient_user_id: recipientId, shared_title: title.trim() || 'お願い', due_at: dueDate ? new Date(dueDate).toISOString() : undefined, reply_due_at: replyDueDate ? new Date(replyDueDate).toISOString() : undefined }; if (rawInputId) await callEdgeFunction(EDGE_FUNCTIONS.confirmRequestDraft, { ...payload, raw_input_id: rawInputId, confirmed_message: message.trim() }); else await callEdgeFunction(EDGE_FUNCTIONS.sendRequest, { ...payload, shared_message: message.trim() }); if (pendingActionId) await callEdgeFunction(EDGE_FUNCTIONS.cancelPendingAction, { pending_action_id: pendingActionId }); onSent(); } catch (err) { setError(err instanceof FamilyOpsApiError ? err.message : '送信に失敗しました。入力内容はこの画面に残っています。'); } finally { setSubmitting(false); } }
  return <form onSubmit={handleSubmit} className="stack-form card request-composer"><div className="composer-steps" aria-label="お願い作成の手順"><span className={!previewing ? 'active' : ''}>1 作成</span><span className={previewing ? 'active' : ''}>2 確認</span><span>3 送信</span></div><p className="eyebrow">相手に見えるのは、確認した文面だけです</p><label>タイトル<input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="未入力なら「お願い」" /></label><label>まずはそのまま入力<textarea value={rawMessage} onChange={(e) => { setRawMessage(e.target.value); setRawInputId(null); }} placeholder="今日ちょっと遅くなるから、迎えをお願いしたい" /></label><button type="button" className="secondary-button" onClick={rewriteMessageWithAi} disabled={submitting || rewriting || rawMessage.trim().length === 0}>{rewriting ? 'AIが言い換え中…' : 'AIでやわらかく言い換える'}</button><label>相手へ送る文面（確認・編集できます）<textarea value={message} onChange={(e) => setMessage(e.target.value)} required placeholder="AIで言い換えるか、直接入力してください" /></label><div className="request-deadline-grid"><label>返事がほしい期限（任意）<input type="datetime-local" value={replyDueDate} onChange={(e) => setReplyDueDate(e.target.value)} /></label><label>作業期限（任意）<input type="datetime-local" value={dueDate} onChange={(e) => setDueDate(e.target.value)} /></label></div><p className="request-scope"><strong>返事期限</strong>は「いつまでに返事がほしいか」、<strong>作業期限</strong>は「いつまでにやるか」です。別々に設定できます。返事期限を空欄にした場合は、送信時にシステムが返事期限を自動提案します。</p><p className="request-scope">📅 今回だけのお願いです。担当変更の「今週だけ」は週画面から選べます。</p>{error && <p role="alert" className="error-text">{error}</p>}{!previewing ? <button type="button" disabled={submitting || !message.trim()} onClick={() => setPreviewing(true)}>送信内容を確認</button> : <section className="line-sender-preview" aria-label="LINE送信プレビュー"><p className="line-preview-kicker">LINE · 送る側の確認</p><h3>この内容で送りますか？</h3><p className="line-preview-message">{message}</p><p className="line-preview-meta">{replyDueDate ? `返事期限: ${new Date(replyDueDate).toLocaleString('ja-JP')}` : '返事期限: 自動提案（送信時に確定）'} / {dueDate ? `作業期限: ${new Date(dueDate).toLocaleString('ja-JP')}` : '作業期限なし'} / 今回だけ</p><p className="empty-hint">送るまでは、相手に通知されません。</p><div className="modal-actions"><button type="button" className="secondary-button" onClick={() => setPreviewing(false)} disabled={subm…3265 tokens truncated…write it. Show item-level conflict.

### 7.2 `大体やった`

`response=mostly_done`:

- snapshot group items (waiting tasks are not implicitly covered)
- create reconciliation session
- **no child task status change**
- suppress “please enter details” reconciliation prompt for those snapshot items

Operational next-day behavior:

- occurrence_ends -> occurrence closes as result unknown; never count failure
- until_done -> remains open and appears in weak `結果未確認` carryover group
- until_deadline -> remains open
- separate_next_occurrence -> next occurrence still materializes independently

### 7.3 Carryover-sensitive minimal follow-up — Final GO MEDIUM-1

Do not turn `大体やった` into a hidden full checklist.

If group includes safety/operationally costly `until_done` items, renderer may ask one compact follow-up after `大体やった`, e.g.:

`残すと明日に影響するものがあります: 洗濯物 / 食器 [どちらも済み] [結果未確認のまま] [個別]`

Rules:

- only carryover-sensitive subset
- one compact prompt
- user can choose `結果未確認のまま`
- no automatic failure

If no meaningful carryover impact, no follow-up.

### 7.4 `個別で答える`

Choose LINE or PWA.

LINE exception-first mode:

- user states exceptions
- server returns explicit preview of tasks that will be marked self-completed
- confirmation applies transaction

Per-item mode remains available but secondary.

## 8. Share / handover commands

### 8.1 Create info

`create-info` input:

- kind share/handover
- confirmed shared text
- visibility
- valid_until optional
- ack policy
- related task/event optional

New household-visible info creates immediate notification intent by default, with policy engine able to downgrade low-impact self/non-action info.

### 8.2 Acknowledge

`ack-info` only records acknowledgement receipt.

It never completes related task.

### 8.3 Correct/update info

Do not destructive overwrite important shared fact without history.

- new version/superseding record or update event
- current active info points to latest
- linked task impact becomes candidate when needed

## 9. Event commands

Conceptual commands:

- `create-family-event`
- `edit-family-event`
- `cancel-family-event`
- `mark-event-waiting-reschedule`
- `link-google-event`
- `resolve-change-candidate`

Event date change does not automatically rewrite completed prep task actuals.

For incomplete relative prep:

- compute proposed reschedule
- if task is purely relative and not protected/manual, candidate can be bulk-confirmed
- reservations/manual confirmed time stay separate protected value and produce warning/conflict

If an individual prep task is awaiting an external response, use Task `set-task-waiting`; `family_event.status=waiting_reschedule` is only for the event itself lacking a settled date, not a substitute for task waiting.

## 10. Candidate resolution

`resolve-change-candidate` input:

- candidate_id
- resolution accept/reject
- expected target revision/current snapshot hash
- optional edited patch

Accept:

- lock candidate + target
- if target changed since candidate creation, mark stale and require refreshed diff
- validate source authority
- apply allowed fields
- update field authority/protection
- audit human resolution

Reject:

- candidate terminal rejected
- no current state change

“latest external wins” path is forbidden.

### Concierge duplicate partial updates

`既存を更新` is a patch of the reviewed canonical entity, not a replacement
form. Omitted owner, work time, and calendar end retain their current values.
A date change retains the existing local work time and calendar end time.
An explicit different owner must use the existing assignment agreement flow;
duplicate matching itself never establishes household consent. The parent
operation receipt replays before revision validation after a lost response.

## 11. Natural language command pipeline

Text/image interpretation is **proposal generation**, not mutation authority.

Pipeline:

1. parse one or multiple intents
2. deterministic validation and household context resolution
3. produce structured candidate list
4. ask only ambiguous parts
5. preview partner-visible wording and impactful changes
6. user confirms
7. execute standard commands

A single message may produce multiple commands, but confirmation should be grouped into one preview.

If only one candidate is ambiguous, do not block already-understood candidates from preview; user can confirm understood subset and resolve ambiguous item separately.

## 12. Notification intent generation

Mutation does not directly call LINE.

Intent includes:

- recipient ActorRef / resolved production recipient when allowed
- semantic type
- related aggregate/current revision
- urgency recommendation
- safety class
- bundle key
- expiry
- actor emphasis policy
- execution/test context

Renderer later reads latest state when practical, preventing stale “未完了” message after task has already completed.

## 13. Duplicate-sensitive completion — Final GO MEDIUM-2

Task `duplicate_sensitivity=avoid_duplicate|safety_critical` changes notification semantics.

When completion changes what another adult should do now:

- create immediate neutral state intent
- text emphasizes state, not performer credit

Examples:

- `朝の薬は対応済みです`
- `お迎えは対応済みです`
- `牛乳の買い物は対応済みです`

Default normal chores do not generate immediate completion push.

For safety-critical medication, current state retrieval must also ensure stale morning LINE action cannot mark/recommend a second administration without showing latest completed state.

## 14. Deep-link command continuity

LINE link carries only opaque resource/session identifiers and route context; no bearer token/private raw text.

After authentication, PWA resolves latest aggregate state server-side.

If LINE link is stale:

- show latest state
- disable invalid old action
- provide next valid action

## 15. Error contract additions

Candidate codes:

- `AGGREGATE_REVISION_CONFLICT`
- `REQUEST_ATTEMPT_STALE`
- `REQUEST_TERMS_REVISION_MISMATCH`
- `TASK_CLAIM_CONFLICT`
- `TASK_ALREADY_COMPLETED`
- `TASK_PERFORMER_CONFLICT`
- `TASK_WAITING_STATE_CONFLICT`
- `ACTOR_SCOPE_CONFLICT`
- `CANDIDATE_STALE`
- `PROTECTED_VALUE_CONFLICT`
- `TEST_SIDE_EFFECT_FORBIDDEN`

Error response must contain safe latest-state hints/deep link where useful, never raw private input/provider secret.

## 16. Worker responsibilities

### Existing workers retained

- webhook inbox processor
- pending action processor
- notification sender
- recurrence materializer
- Google sync worker

### New/extended scheduled logic

- expire request attempts
- compose morning/evening Daily Brief notifications
- surface waiting tasks whose next_check_at is due
- warn waiting tasks near hard due_at without auto-resume
- source document processing queue
- retention cleanup

Do not create one cron per household/task. Workers evaluate due rows from DB schedules.

## 17. State-machine invariants for tests

Mandatory property/invariant tests:

- terminal request attempt never reopens
- same terms revision must be confirmed by both required ActorRefs for consultation acceptance
- accepted Request execution status derives from linked task only
- `mostly_done` never completes child task
- waiting never becomes completion/failure and normal nag is suppressed until check/deadline risk
- next-check surfacing does not auto-resume waiting task
- skipped new writes always carry recognized outcome_reason
- rule change never rewrites non-rule assignment source
- anyone claim never changes assignment_mode
- takeover and completion race yields one coherent final state
- duplicate completion never silently replaces performer
- simulated performer/confirm/assignee is persisted as simulated ActorRef, never operator real ActorRef
- production aggregate cannot reference simulated ActorRef
- candidate cannot apply over newer target revision
- simulated actor cannot create production external side effect
- after semantic point-of-no-return, feature-off cannot restore legacy current-truth mutation/read semantics
### Lane A implementation contract — CF-01 / CF-12

Request assignment negotiation uses `fn_command_transition_request_attempt_v1` for both channels. The server-issued `terms.assignment_targets` array contains each scoped task ID, observed revision and original assignee ActorRef. Acceptance validates and locks the entire snapshot in task-ID order, then updates every assignment, agreement provenance, linked task and receipt in the same transaction. `assignment_change_request_tasks` is historical input only; new requests do not write or consult it.

Every response carries the observed attempt ID, attempt revision and terms revision. An ID-only legacy acceptance is not upgraded to current consent: it returns stale and asks the person to reopen the current proposal. Expiry closes all four nonterminal states using `RequestAttempt.reply_due_at`, preserving task assignment. A late response returns `reproposal_required`; it cannot revive the old attempt. Periodic expiry uses the same expiry helper as the transition command.

The common reply-deadline proposal rule is: when work lies in the future, propose the earlier of 24 hours after creation or halfway between creation and work; otherwise propose 24 hours after creation. Explicit user-specified future response deadlines take precedence even when later than work. The deadline is proposed once and persisted on the attempt; replay never recalculates it. Work dates remain execution data. This rule implements Q47's configurable automatic proposal; it does not redefine Q30/Q36 agreement semantics.

Implementation verification is tracked in `docs/implementation/LANE-A-REQUEST-CANONICALIZATION.md`. This contract is a review candidate until the independent review gate passes.
