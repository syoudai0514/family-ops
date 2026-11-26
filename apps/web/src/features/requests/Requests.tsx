import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent, type Ref } from 'react';
import { AssignmentPreview } from './AssignmentPreview';
import { useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from '../../app/AuthContext';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { useCommandAttempt } from '../../lib/useCommandAttempt';
import { loadStableCommandAttempt, type CommandAttempt } from '../../lib/commandAttempt';
import { formatDateTimeJa, tokyoDateTimeInputToIso } from '../../lib/date';
import type { PendingAction, RequestRow } from '../../lib/types';

export const REQUEST_ATTEMPT_SELECT = 'id,request_id,attempt_kind,state,revision,terms_revision,terms,reply_due_at,request_attempt_confirmations(actor_ref_id,terms_revision)';

interface RequestAttempt {
  id: string;
  request_id: string;
  state: 'pending' | 'checking' | 'consulting' | 'awaiting_confirmation' | 'accepted' | 'declined' | 'expired' | 'cancelled';
  attempt_kind?: 'initial' | 'reproposal' | 'change' | 'cancel';
  revision: number;
  terms_revision: number;
  request_attempt_confirmations?: { actor_ref_id: string; terms_revision: number }[];
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

function bucketForRequest(request: RequestRow, attempt?: RequestAttempt): RequestBucket {
  if (request.status === 'completed') return 'history';
  return requestBucket(attempt?.state ?? request.status, responseDeadline(attempt));
}

function useRequests(householdId: string | null) {
  const [snapshot, setSnapshot] = useState<{ requests: RequestRow[]; attempts: Map<string, RequestAttempt> }>({
    requests: [],
    attempts: new Map(),
  });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const loadSequence = useRef(0);

  const load = useCallback(async () => {
    const sequence = ++loadSequence.current;
    if (!householdId) {
      setSnapshot({ requests: [], attempts: new Map() });
      setLoading(false);
      return;
    }

    setError(null);
    try {
      const { data, error: fetchError } = await supabase
        .from('requests')
        .select('*')
        .eq('household_id', householdId)
        .order('due_at', { ascending: true, nullsFirst: false });
      if (fetchError) throw fetchError;

      const rows = (data ?? []) as RequestRow[];
      const taskIds = rows.map((row) => row.linked_task_instance_id).filter((id): id is string => Boolean(id));
      const requestIds = rows.map((row) => row.id);
      const [attemptsResult, tasksResult] = await Promise.all([
        requestIds.length ? supabase.from('request_attempts').select(REQUEST_ATTEMPT_SELECT)
          .in('request_id', requestIds).is('test_context_id', null).order('created_at', { ascending: false })
          : { data: [], error: null },
        taskIds.length ? supabase.from('task_instances').select('id, revision, title, due_at').in('id', taskIds)
          : { data: [], error: null },
      ]);
      if (sequence !== loadSequence.current) return;
      if (attemptsResult.error) throw attemptsResult.error;
      if (tasksResult.error) setError(tasksResult.error.message);

      const attempts = new Map<string, RequestAttempt>();
      for (const attempt of (attemptsResult.data ?? []) as RequestAttempt[]) {
        if (!attempts.has(attempt.request_id)) attempts.set(attempt.request_id, attempt);
      }
      const tasks = new Map((tasksResult.data ?? []).map((task) => [task.id, task]));
      const requests = rows.map((row) => {
        const task = row.linked_task_instance_id ? tasks.get(row.linked_task_instance_id) : undefined;
        return task ? { ...row, linked_task_revision: task.revision, linked_task_title: task.title, linked_task_due_at: task.due_at } : row;
      });
      setSnapshot({ requests, attempts });
    } catch (err) {
      if (sequence !== loadSequence.current) return;
      const message = typeof err === 'object' && err && 'message' in err && typeof err.message === 'string'
        ? err.message
        : '時間をおいてもう一度お試しください。';
      setError(message);
    } finally {
      if (sequence === loadSequence.current) setLoading(false);
    }
  }, [householdId]);

  useEffect(() => {
    void load();
    function refreshOnReturn() {
      if (document.visibilityState === 'visible') void load();
    }
    document.addEventListener('visibilitychange', refreshOnReturn);
    return () => {
      loadSequence.current += 1;
      document.removeEventListener('visibilitychange', refreshOnReturn);
    };
  }, [load]);
  return { ...snapshot, loading, error, refresh: load };
}

export function Requests() {
  const { user } = useAuth();
  const { household, partner } = useHousehold();
  const { requests, attempts, loading, error, refresh } = useRequests(household?.id ?? null);
  const recipientName = partner?.family_role === 'papa'
    ? 'パパ'
    : partner?.family_role === 'mama' ? 'ママ' : partner?.profile?.display_name.trim() || 'パートナー';
  const location = useLocation();
  const navigate = useNavigate();
  const restoreScrollY = typeof (location.state as { restoreScrollY?: unknown } | null)?.restoreScrollY === 'number'
    ? Number((location.state as { restoreScrollY: number }).restoreScrollY) : null;
  const pendingActionRawText = typeof (location.state as { pendingActionRawText?: unknown } | null)?.pendingActionRawText === 'string'
    ? (location.state as { pendingActionRawText: string }).pendingActionRawText
    : '';
  const params = new URLSearchParams(location.search);
  const pendingId = params.get('pending');
  const targetRequestId = params.get('request');
  const otherResponseRequestId = params.get('response') === 'other' ? targetRequestId : null;
  const [pendingAction, setPendingAction] = useState<PendingAction | null>(null);
  const [pendingLoadError, setPendingLoadError] = useState<string | null>(null);
  const [showForm, setShowForm] = useState(() => Boolean(pendingId) || new URLSearchParams(location.search).has('date') || Boolean(pendingActionRawText));
  const [sendStatus, setSendStatus] = useState<string | null>(null);
  const rawBucket = params.get('bucket');
  const restoredRef = useRef(false);
  const targetRowRef = useRef<HTMLLIElement | null>(null);
  const incoming = requests.filter((r) => r.recipient_id === user?.id);
  const outgoing = requests.filter((r) => r.requester_id === user?.id);
  const targetRequest = incoming.find((r) => r.id === targetRequestId) ?? outgoing.find((r) => r.id === targetRequestId);
  const targetAttempt = targetRequest && attempts.get(targetRequest.id);
  const hasTarget = Boolean(targetRequest);
  const bucketFilter = targetRequest
    ? bucketForRequest(targetRequest, targetAttempt)
    : rawBucket === 'expired' || rawBucket === 'history' ? rawBucket : 'active';

  function selectBucket(bucket: RequestBucket) {
    const next = new URLSearchParams(location.search);
    next.set('bucket', bucket);
    next.delete('request');
    next.delete('response');
    navigate(`${location.pathname}?${next.toString()}`, { replace: true, state: location.state });
  }
  const bucketedIncoming = incoming.filter((r) => bucketForRequest(r, attempts.get(r.id)) === bucketFilter);
  const bucketedOutgoing = outgoing.filter((r) => bucketForRequest(r, attempts.get(r.id)) === bucketFilter);
  const counts = useMemo(() => (['active', 'expired', 'history'] as RequestBucket[]).reduce<Record<RequestBucket, number>>((acc, bucket) => {
    acc[bucket] = requests.filter((r) => bucketForRequest(r, attempts.get(r.id)) === bucket).length;
    return acc;
  }, { active: 0, expired: 0, history: 0 }), [requests, attempts]);
  const rowRefresh = useCallback(async () => {
    const scrollY = window.scrollY;
    await refresh();
    if (!targetRequestId) requestAnimationFrame(() => window.scrollTo({ top: scrollY, behavior: 'auto' }));
  }, [refresh, targetRequestId]);

  useEffect(() => {
    if (restoredRef.current || restoreScrollY == null || targetRequestId) return;
    restoredRef.current = true;
    requestAnimationFrame(() => window.scrollTo({ top: restoreScrollY, behavior: 'auto' }));
  }, [restoreScrollY, targetRequestId]);

  useEffect(() => {
    const row = targetRowRef.current;
    if (!targetRequestId || !row) return;
    row.focus({ preventScroll: true });
    row.scrollIntoView?.({ block: 'center' });
  }, [targetRequestId, bucketFilter, hasTarget, otherResponseRequestId]);

  useEffect(() => {
    let cancelled = false;
    setPendingAction(null);
    setPendingLoadError(null);
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

  function clearPrivatePrefill(showSentRequest = false) {
    const params = new URLSearchParams(location.search);
    params.delete('pending');
    params.delete('date');
    if (showSentRequest) {
      params.set('bucket', 'active');
      params.delete('request');
      params.delete('response');
    }
    const search = params.toString();
    navigate(`${location.pathname}${search ? `?${search}` : ''}`, { replace: true, state: null });
  }

  if (loading) return <div className="app-shell">読み込み中…</div>;

  return (
    <div className="app-shell">
      <div className="today-header">
        <h1>お願い</h1>
        {partner && <button type="button" onClick={() => { setShowForm((v) => !v); setSendStatus(null); if (showForm) clearPrivatePrefill(); }}>{showForm ? '閉じる' : '+ お願いを送る'}</button>}
      </div>
      <div className="request-bucket-tabs" role="group" aria-label="お願いの状態">
        <button type="button" className={bucketFilter === 'active' ? 'active' : 'secondary-button'} aria-pressed={bucketFilter === 'active'} onClick={() => selectBucket('active')}>対応中 {counts.active}</button>
        <button type="button" className={bucketFilter === 'expired' ? 'active' : 'secondary-button'} aria-pressed={bucketFilter === 'expired'} onClick={() => selectBucket('expired')}>期限切れ {counts.expired}</button>
        <button type="button" className={bucketFilter === 'history' ? 'active' : 'secondary-button'} aria-pressed={bucketFilter === 'history'} onClick={() => selectBucket('history')}>履歴 {counts.history}</button>
      </div>
      {targetRequestId && !targetRequest && !error && <p role="status">このお願いは見つかりませんでした。</p>}
      {error && <section className="card state-card" role="alert"><b>お願いを読み込めませんでした</b><p>{error}</p><button type="button" onClick={() => void refresh()}>再読み込み</button></section>}
      {pendingLoadError && <p role="alert" className="error-text">{pendingLoadError}</p>}
      {showForm && pendingId && pendingAction?.id !== pendingId && !pendingLoadError && <p role="status">LINEの下書きを読み込み中…</p>}
      {sendStatus && <p role="status">{sendStatus}</p>}
      {showForm && partner && (!pendingId || pendingAction?.id === pendingId) && (
        <SendRequestForm
          key={`${partner.user_id}:${pendingId ?? 'direct'}`}
          recipientId={partner.user_id}
          recipientName={recipientName}
          initialRawMessage={String(pendingAction?.normalized_payload.raw_text ?? pendingActionRawText)}
          initialMessage={String(pendingAction?.normalized_payload.shared_message ?? '')}
          initialTitle={String(pendingAction?.normalized_payload.title ?? '')}
          initialDueDate={pendingAction ? toDateTimeLocal(pendingAction.normalized_payload.due_at) : ''}
          pendingActionId={pendingAction?.id ?? null}
          onSent={(status) => {
            setShowForm(false);
            setSendStatus(status);
            clearPrivatePrefill(true);
            void rowRefresh();
          }}
        />
      )}

      <section className="card">
        <h2>受け取ったお願い</h2>
        {bucketedIncoming.length === 0 ? <p className="empty-hint">この状態のお願いはありません。</p> : <ul className="request-list">{bucketedIncoming.map((r) => <IncomingRequestRow key={r.id} request={r} attempt={attempts.get(r.id)} onChanged={rowRefresh} showOtherFromLink={r.id === otherResponseRequestId} rowRef={r.id === targetRequestId ? targetRowRef : undefined} />)}</ul>}
      </section>
      <section className="card">
        <h2>送ったお願い</h2>
        {bucketedOutgoing.length === 0 ? <p className="empty-hint">この状態のお願いはありません。</p> : <ul className="request-list">{bucketedOutgoing.map((r) => <OutgoingRequestRow key={r.id} request={r} attempt={attempts.get(r.id)} onChanged={rowRefresh} rowRef={r.id === targetRequestId ? targetRowRef : undefined} />)}</ul>}
      </section>
    </div>
  );
}

function requestStatusLabel(request: RequestRow, attempt?: RequestAttempt): string {
  if (request.status === 'completed') return '完了';
  const followup = attempt?.attempt_kind === 'change' ? '変更案' : attempt?.attempt_kind === 'cancel' ? '取り消し案' : null;
  const state = attempt?.state ?? request.status;
  if (attempt && requestBucket(state, responseDeadline(attempt)) === 'expired') {
    return followup ? `${followup}の返事期限切れ` : '返事期限切れ';
  }
  switch (state) {
    case 'pending': return '返事待ち';
    case 'checking': return '引き受けられるか確認中';
    case 'consulting': return '相談中';
    case 'awaiting_confirmation': return followup ? `${followup}の確認中` : '変更案の確認中';
    case 'accepted': return followup ? `${followup}を反映済み` : '引き受け済み';
    case 'declined': return followup ? `${followup}は見送り` : '引き受けは難しい';
    case 'cancelled': return followup ? `${followup}を取り下げ済み` : '取り下げ済み';
    default: return '返事期限切れ';
  }
}

export function IncomingRequestRow({ request, attempt, onChanged, showOtherFromLink = false, rowRef }: { request: RequestRow; attempt?: RequestAttempt; onChanged: () => Promise<void> | void; showOtherFromLink?: boolean; rowRef?: Ref<HTMLLIElement> }) {
  const [busy, setBusy] = useState(false); const [error, setError] = useState<string | null>(null); const [otherOverride, setOtherOverride] = useState<boolean>(); const [confirmAccept, setConfirmAccept] = useState(false); const [previewReady, setPreviewReady] = useState(false); const run = useCommandAttempt();
  async function respond(kind: 'accept' | 'decline' | 'checking' | 'consult') {
    if (!attempt) { setError('このお願いは最新状態に更新してください。'); return; }
    setBusy(true); setError(null);
    try {
      const functionName = kind === 'checking' || kind === 'consult' ? EDGE_FUNCTIONS.respondRequest : kind === 'accept' && request.assignment_task_instance_id ? EDGE_FUNCTIONS.acceptAssignmentChangeRequest : kind === 'accept' ? EDGE_FUNCTIONS.acceptRequest : EDGE_FUNCTIONS.declineRequest;
      const result = await run<{ reproposal_required?: boolean }>(`request:${attempt.id}:${kind}:r${attempt.revision}:terms${attempt.terms_revision}`, functionName, operation_id => ({ operation_id, request_id: request.id, attempt_id: attempt.id, expected_revision: attempt.revision, expected_terms_revision: attempt.terms_revision, ...(kind === 'checking' || kind === 'consult' ? { response_action: kind } : {}) }));
      if (result.reproposal_required) setError('返事の期限が過ぎました。もう一度お願いする場合は、新しく送ってください。');
      if (kind === 'accept') setConfirmAccept(false);
      await onChanged();
    } catch (err) { setError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。最新状態を読み直してください。'); } finally { setBusy(false); }
  }
  async function negotiate(action: 'checking' | 'consult' | 'edit_terms' | 'confirm_terms' | 'decline', terms?: Record<string, unknown>) {
    if (!attempt) { setError('このお願いは最新状態に更新してください。'); return; }
    setBusy(true); setError(null);
    try {
      const result = await run<{ reproposal_required?: boolean }>(`request:${attempt.id}:${action}:r${attempt.revision}:${JSON.stringify(terms ?? {})}`, EDGE_FUNCTIONS.negotiateRequest, operation_id => ({ operation_id, request_id: request.id, attempt_id: attempt.id, action, terms, expected_revision: attempt.revision, expected_terms_revision: attempt.terms_revision }));
      if (result.reproposal_required) setError('返事の期限が過ぎました。もう一度お願いする場合は、新しく送ってください。');
      await onChanged();
    } catch (err) { setError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。最新状態を読み直してください。'); } finally { setBusy(false); }
  }
  const replyDueAt = responseDeadline(attempt);
  const isAssignmentChange = Boolean(request.assignment_task_instance_id);
  const isActive = Boolean(attempt && requestBucket(attempt.state, responseDeadline(attempt)) === 'active');
  const showOther = otherOverride ?? showOtherFromLink;
  const canReply = isActive && (attempt?.state === 'pending' || attempt?.state === 'checking');
  return <li className="request-item" ref={rowRef} tabIndex={rowRef ? -1 : undefined}>
    <div>
      <strong>{request.shared_title}</strong> — {requestStatusLabel(request, attempt)}
      {isAssignmentChange && <div className="task-item-meta">{request.assignment_scope === 'this_week' ? '今週だけ' : '今回だけ'}の担当変更</div>}
      {request.shared_message && <p className="request-shared-message">{request.shared_message}</p>}
      {replyDueAt && <span className="task-item-meta">返事期限: {formatDateTimeJa(replyDueAt)}</span>}
      {request.due_at && <span className="task-item-meta">作業期限: {formatDateTimeJa(request.due_at)}</span>}
    </div>
    {canReply && !confirmAccept && (
      <div className="task-item-actions">
        {isAssignmentChange
          ? <button type="button" disabled={busy} onClick={() => { setPreviewReady(false); setConfirmAccept(true); }}>引き受ける</button>
          : <button type="button" disabled={busy} onClick={() => respond('accept')}>引き受ける</button>}
        <button type="button" disabled={busy} onClick={() => respond('decline')}>難しい</button>
        {isAssignmentChange
          ? <button type="button" className="text-button" disabled={busy} onClick={() => negotiate('consult')}>相談する</button>
          : <button type="button" className="text-button" aria-expanded={showOther} disabled={busy} onClick={() => setOtherOverride(!showOther)}>その他の返答</button>}
      </div>
    )}
    {canReply && isAssignmentChange && confirmAccept && (
      <div className="request-other-actions" aria-label="担当変更の最終確認">
        <p><strong>この担当変更を引き受けますか？</strong></p>
        <p className="task-item-meta">{request.due_at ? `${formatDateTimeJa(request.due_at)} / ` : ''}{request.assignment_scope === 'this_week' ? '今週だけ' : '今回だけ'}</p>
        <AssignmentPreview key={`${attempt?.id}:${attempt?.revision}:${attempt?.terms_revision}`} requestId={request.id} attemptId={attempt?.id ?? ''} expectedRevision={attempt?.revision ?? 0} expectedTermsRevision={attempt?.terms_revision ?? 0} onReady={setPreviewReady} />
        <div className="task-item-actions">
          <button type="button" disabled={busy || !previewReady} onClick={() => respond('accept')}>引き受ける</button>
          <button type="button" className="text-button" disabled={busy} onClick={() => setConfirmAccept(false)}>戻る</button>
        </div>
      </div>
    )}
    {canReply && !isAssignmentChange && showOther && <div className="request-response-options">
      {attempt?.state === 'pending' && <button type="button" className="secondary-button" disabled={busy} onClick={() => negotiate('checking')}>確認してから返事する</button>}
      <button type="button" className="secondary-button" disabled={busy} onClick={() => negotiate('consult')}>相談する</button>
      <CommentedDecline busy={busy} onSubmit={(comment) => negotiate('decline', { comment })} />
    </div>}
    {isActive && attempt && ['consulting', 'awaiting_confirmation'].includes(attempt.state) &&
      <ConsultationTerms key={`${attempt.id}:${attempt.terms_revision}`} request={request} attempt={attempt} actorRefId={request.recipient_actor_ref_id} busy={busy} onAction={negotiate} />}
    {attempt?.state === 'accepted' && <AgreedProposal request={request} attempt={attempt} />}
    {error && <p role="alert" className="error-text">{error}</p>}
  </li>;
}

function CommentedDecline({ busy, onSubmit }: { busy: boolean; onSubmit: (comment: string) => void }) { const [comment, setComment] = useState(''); return <div className="request-comment-row"><input aria-label="難しい理由（任意）" value={comment} onChange={(event) => setComment(event.target.value)} placeholder="コメント付きで難しい" /><button type="button" className="secondary-button" disabled={busy} onClick={() => onSubmit(comment)}>コメント付きで難しい</button></div>; }
function ConsultationTerms({ request, attempt, actorRefId, busy, onAction }: { request: RequestRow; attempt: RequestAttempt; actorRefId?: string | null; busy: boolean; onAction: (action: 'edit_terms' | 'confirm_terms', terms?: Record<string, unknown>) => void }) {
  const savedMemo = typeof attempt.terms?.candidate === 'string' ? attempt.terms.candidate : '';
  const savedPatch = attempt.terms?.material_patch && typeof attempt.terms.material_patch === 'object' ? attempt.terms.material_patch as Record<string, unknown> : null;
  const savedWorkDue = typeof savedPatch?.work_due_at === 'string' ? toDateTimeLocal(savedPatch.work_due_at) : '';
  const [memo, setMemo] = useState(savedMemo);
  const [privateMemo, setPrivateMemo] = useState('');
  const [rewriting, setRewriting] = useState(false);
  const [rewriteError, setRewriteError] = useState<string | null>(null);
  async function softenProposal() {
    if (!privateMemo.trim() || rewriting) return;
    setRewriting(true); setRewriteError(null);
    try {
      const proposal = await callEdgeFunction<{ proposed_text: string }>(EDGE_FUNCTIONS.proposeAiDraft, { operation_id: newOperationId(), raw_text: privateMemo.trim(), target_type: 'consultation' });
      setMemo(proposal.proposed_text);
    } catch { setRewriteError('AIの提案を作れませんでした。入力は残っています。再試行するか、送る文面を直接入力してください。'); }
    finally { setRewriting(false); }
  }
  const [workDue, setWorkDue] = useState(savedWorkDue);
  const weeklyAssignment = Boolean(request.assignment_task_instance_id && request.assignment_scope === 'this_week');
  const dirty = memo.trim() !== savedMemo.trim() || workDue !== savedWorkDue;
  const savedAssignment = savedPatch?.assignment && typeof savedPatch.assignment === 'object' ? savedPatch.assignment as Record<string, unknown> : null;
  const assignmentIsExplicit = savedAssignment?.mode === 'request_recipient';
  const confirmations = attempt.request_attempt_confirmations?.filter(confirmation =>
    confirmation.terms_revision === attempt.terms_revision,
  );
  const alreadyConfirmed = confirmations?.some(confirmation => confirmation.actor_ref_id === actorRefId);
  const partnerConfirmed = Boolean(actorRefId && confirmations?.some(confirmation => confirmation.actor_ref_id !== actorRefId));
  const awaitingConfirmation = attempt.state === 'awaiting_confirmation';
  const followup = attempt.attempt_kind === 'change' || attempt.attempt_kind === 'cancel';
  const confirmLabel = attempt.attempt_kind === 'cancel' ? '取り消しに同意する' : 'この案に同意する';

  function propose() {
    const nextTerms: Record<string, unknown> = { ...attempt.terms, candidate: memo.trim() };
    if (workDue !== savedWorkDue) {
      if (workDue) {
        const materialPatch: Record<string, unknown> = {
          version: 1,
          work_due_at: tokyoDateTimeInputToIso(workDue),
          scheduled_date: workDue.slice(0, 10),
        };
        if (request.assignment_task_instance_id) {
          materialPatch.assignment = { mode: 'request_recipient', targets: attempt.terms?.assignment_targets };
        }
        nextTerms.material_patch = materialPatch;
      } else {
        delete nextTerms.material_patch;
      }
    }
    onAction('edit_terms', nextTerms);
  }

  return <div className="request-consultation" aria-label="相談の条件">
    {followup ? <FollowupProposal request={request} attempt={attempt} /> : <div className="request-consultation-summary">
      <strong>いまの相談案</strong>
      {savedMemo && <p className="request-shared-message">{savedMemo}</p>}
      {savedWorkDue && <p>作業期限を {formatDateTimeJa(String(savedPatch?.work_due_at))} に変更</p>}
      {request.assignment_task_instance_id && <p>{assignmentIsExplicit ? 'この作業をお願いされた人に変更' : '元の担当変更の内容を引き継ぎます。'}</p>}
      {!savedMemo && !savedWorkDue && !request.assignment_task_instance_id && <p>新しい案はまだありません。</p>}
    </div>}
    <p className="task-item-meta">二人が同じ案に同意すると反映されます。</p>
    {awaitingConfirmation && <p role="status">{alreadyConfirmed ? 'あなたは同意済みです。相手の返事を待っています。' : partnerConfirmed ? '相手は同意済みです。内容を見て返事をしてください。' : '同意の状況を確認中です。'}</p>}
    {!followup && <details className="request-private-draft">
      <summary>AIで相談文を整える</summary>
      <label>気持ちや事情のメモ（相手には送りません）<textarea value={privateMemo} disabled={busy || rewriting} onChange={event => setPrivateMemo(event.target.value)} placeholder="何が難しいか、どうなら引き受けられるか" /></label>
      <button type="button" className="secondary-button" disabled={busy || rewriting || !privateMemo.trim()} onClick={() => void softenProposal()}>{rewriting ? '相談文を作成中…' : 'AIで相談文を作る'}</button>
      {rewriteError && <p role="alert">{rewriteError}</p>}
    </details>}
    {!followup && <>
      <label>相手へ送る相談文<textarea rows={3} value={memo} disabled={busy || rewriting} onChange={(event) => setMemo(event.target.value)} placeholder="例：18時半ならお迎えに行けそう" /></label>
      {weeklyAssignment ? <p className="task-item-meta">時刻を変えたい日は、その日の予定から相談できます。</p>
        : <label>変更後の作業期限（任意）<input type="datetime-local" value={workDue} disabled={busy || rewriting} onChange={(event) => setWorkDue(event.target.value)} /></label>}
    </>}
    <div className="task-item-actions">
      {!alreadyConfirmed && <button type="button" disabled={busy || rewriting || dirty} onClick={() => onAction('confirm_terms')}>{confirmLabel}</button>}
      {!followup && <button type="button" className="secondary-button" disabled={busy || rewriting || !dirty} onClick={propose}>相談案を送る</button>}
    </div>
  </div>;
}

function AgreedProposal({ request, attempt }: { request: RequestRow; attempt: RequestAttempt }) {
  if (attempt.attempt_kind === 'change' || attempt.attempt_kind === 'cancel') {
    return <FollowupProposal request={request} attempt={attempt} />;
  }
  const memo = typeof attempt.terms?.candidate === 'string' ? attempt.terms.candidate : '';
  const patch = attempt.terms?.material_patch as Record<string, unknown> | undefined;
  const workDue = typeof patch?.work_due_at === 'string' ? formatDateTimeJa(patch.work_due_at) : '';
  if (!memo && !workDue) return null;
  return <div className="request-consultation-summary">
    <strong>二人が同意した内容</strong>
    {memo && <p className="request-shared-message">{memo}</p>}
    {workDue && <p>作業期限を {workDue} に変更</p>}
  </div>;
}

function FollowupProposal({ request, attempt }: { request: RequestRow; attempt: RequestAttempt }) {
  const patch = attempt.terms?.task_patch as Record<string, unknown> | undefined;
  const reason = typeof attempt.terms?.reason === 'string' ? attempt.terms.reason : null;
  const title = typeof patch?.title === 'string' ? patch.title : null;
  const scheduledDate = typeof patch?.scheduled_date === 'string' ? patch.scheduled_date : null;
  const workDue = typeof patch?.due_at === 'string' ? formatDateTimeJa(patch.due_at) : null;
  return <div className="request-consultation-summary">
    <strong>{attempt.attempt_kind === 'cancel' ? '引き受けた作業を取り消す案' : '引き受けた作業の変更案'}</strong>
    {reason && <p className="request-shared-message">{reason}</p>}
    {title && <p>内容を「{title}」に変更</p>}
    {scheduledDate && <p>作業日を {scheduledDate} に変更</p>}
    {workDue && <p>作業期限を {workDue} に変更</p>}
    {patch?.due_at === null && <p>作業期限を外す</p>}
    {patch?.assignment_mode === 'anyone' && <p>担当を「誰でも」に変更</p>}
    {patch?.assignment_mode === 'unassigned' && <p>担当を外す</p>}
    {patch?.assignment_mode === 'person' && <p>担当を{patch.assignee_actor_ref_id === request.requester_actor_ref_id ? 'お願いした人' : patch.assignee_actor_ref_id === request.recipient_actor_ref_id ? '引き受けた人' : '指定された人'}に変更</p>}
  </div>;
}

export function OutgoingRequestRow({ request, attempt, onChanged, rowRef }: { request: RequestRow; attempt?: RequestAttempt; onChanged: () => Promise<void> | void; rowRef?: Ref<HTMLLIElement> }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [withdrawSnapshot, setWithdrawSnapshot] = useState<string | null>(null);

  async function cancel() {
    if (!attempt) return;
    setBusy(true);
    setError(null);
    try {
      const result = await callEdgeFunction<{ reproposal_required?: boolean }>(EDGE_FUNCTIONS.cancelRequest, {
        operation_id: newOperationId(), request_id: request.id, attempt_id: attempt.id,
        expected_revision: attempt.revision, expected_terms_revision: attempt.terms_revision,
      });
      if (result.reproposal_required) setError('返事の期限が過ぎました。');
      setWithdrawSnapshot(null);
      await onChanged();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '取り下げられませんでした。お願いの最新の状態を確認してください。');
    } finally {
      setBusy(false);
    }
  }

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
  const isActive = Boolean(attempt && requestBucket(attempt.state, replyDueAt) === 'active');
  const isFollowup = attempt?.attempt_kind === 'change' || attempt?.attempt_kind === 'cancel';
  const attemptSnapshot = attempt ? `${attempt.id}:${attempt.revision}` : null;
  return <li className="request-item" ref={rowRef} tabIndex={rowRef ? -1 : undefined}>
    <div>
      <strong>{request.shared_title}</strong> — {requestStatusLabel(request, attempt)}
      {request.assignment_task_instance_id && <div className="task-item-meta">{request.assignment_scope === 'this_week' ? '今週だけ' : '今回だけ'}の担当変更</div>}
      {request.shared_message && <p className="request-shared-message">{request.shared_message}</p>}
      {replyDueAt && <span className="task-item-meta">返事期限: {formatDateTimeJa(replyDueAt)}</span>}
      {request.due_at && <span className="task-item-meta">作業期限: {formatDateTimeJa(request.due_at)}</span>}
    </div>
    {isActive && attempt && ['consulting', 'awaiting_confirmation'].includes(attempt.state) &&
      <ConsultationTerms key={`${attempt.id}:${attempt.terms_revision}`} request={request} attempt={attempt} actorRefId={request.requester_actor_ref_id} busy={busy} onAction={negotiate} />}
    {isActive && attempt && (withdrawSnapshot === attemptSnapshot
      ? <div className="request-response-options" aria-label="取り下げの確認">
        <p>{isFollowup ? 'この相談案を取り下げますか？' : 'このお願いを取り下げますか？'}</p>
        <div className="task-item-actions">
          <button type="button" className="secondary-button" disabled={busy} onClick={() => setWithdrawSnapshot(null)}>戻る</button>
          <button type="button" disabled={busy} onClick={() => void cancel()}>取り下げる</button>
        </div>
      </div>
      : <button type="button" className="text-button" disabled={busy} onClick={() => setWithdrawSnapshot(attemptSnapshot)}>{isFollowup ? '相談案を取り下げる' : 'お願いを取り下げる'}</button>)}
    {request.status === 'accepted' && !isActive && <AcceptedRequestFollowup key={request.revision} request={request} onChanged={onChanged} />}
    {attempt?.state === 'accepted' && <AgreedProposal request={request} attempt={attempt} />}
    {error && <p role="alert" className="error-text">{error}</p>}
  </li>;
}

function AcceptedRequestFollowup({ request, onChanged }: { request: RequestRow; onChanged: () => Promise<void> | void }) {
  const [mode, setMode] = useState<'change' | 'cancel' | null>(null); const [title, setTitle] = useState(request.linked_task_title ?? request.shared_title); const [replyDueAt, setReplyDueAt] = useState(''); const [busy, setBusy] = useState(false); const [error, setError] = useState<string | null>(null); const canPropose = typeof request.revision === 'number' && typeof request.linked_task_revision === 'number';
  async function submit() { if (!mode || !canPropose) return; if (mode === 'change' && !title.trim()) { setError('変更後の内容を入力してください。'); return; } setBusy(true); setError(null); try { await callEdgeFunction(EDGE_FUNCTIONS.startRequestFollowup, { operation_id: newOperationId(), request_id: request.id, attempt_kind: mode, task_patch: mode === 'change' ? { title: title.trim() } : undefined, reply_due_at: replyDueAt ? tokyoDateTimeInputToIso(replyDueAt) : undefined, expected_request_revision: request.revision, expected_task_revision: request.linked_task_revision }); setMode(null); await onChanged(); } catch (err) { setError(err instanceof FamilyOpsApiError ? err.message : '提案を送れませんでした。最新の状態を確認してください。'); } finally { setBusy(false); } }
  if (!request.linked_task_instance_id) return null;
  return <div className="request-followup">{!mode ? <div className="task-item-actions"><button type="button" className="secondary-button" disabled={!canPropose} onClick={() => setMode('change')}>変更を相談</button><button type="button" className="text-button" disabled={!canPropose} onClick={() => setMode('cancel')}>取消を相談</button></div> : <div className="stack-form request-followup-form"><p className="task-item-meta">{mode === 'change' ? '変更案を二人で確認してから反映します。' : '取消は相手の確認後にだけ反映します。'}</p>{mode === 'change' && <label>変更後の内容<input value={title} onChange={(event) => setTitle(event.target.value)} /></label>}<label>返事がほしい期限（任意）<input type="datetime-local" value={replyDueAt} onChange={(event) => setReplyDueAt(event.target.value)} /></label><div className="task-item-actions"><button type="button" disabled={busy} onClick={() => void submit()}>{busy ? '送信中…' : '確認をお願いする'}</button><button type="button" className="text-button" disabled={busy} onClick={() => setMode(null)}>やめる</button></div></div>}{!canPropose && <p className="task-item-meta">このお願いは最新情報を読み直してから変更・取消できます。</p>}{error && <p role="alert" className="error-text">{error}</p>}</div>;
}

function toDateTimeLocal(value: unknown): string { if (typeof value !== 'string' || !value) return ''; const date = new Date(value); if (Number.isNaN(date.getTime())) return ''; const parts = new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Tokyo', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(date).reduce<Record<string, string>>((result, part) => ({ ...result, [part.type]: part.value }), {}); return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}`; }

function SendRequestForm({
  recipientId, recipientName, initialRawMessage = '', initialMessage = '', initialTitle = '',
  initialDueDate = '', pendingActionId = null, onSent,
}: {
  recipientId: string;
  recipientName: string;
  initialRawMessage?: string;
  initialMessage?: string;
  initialTitle?: string;
  initialDueDate?: string;
  pendingActionId?: string | null;
  onSent: (status: string) => void;
}) {
  const { user } = useAuth();
  const { household } = useHousehold();
  const runCommand = useCommandAttempt();
  const logicalKey = `request:send:${recipientId}:${pendingActionId ?? 'direct'}`;
  const [lockedAttempt, setLockedAttempt] = useState<CommandAttempt | null>(null);
  const [title, setTitle] = useState(initialTitle);
  const [message, setMessage] = useState(initialMessage);
  const [replyDueDate, setReplyDueDate] = useState('');
  const [dueDate, setDueDate] = useState(initialDueDate);
  const [submitting, setSubmitting] = useState(false);
  const [rewriting, setRewriting] = useState(false);
  const [rawInputId, setRawInputId] = useState<string | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const sharedTitle = title.trim() || 'お願い';
  const sharedMessage = message.trim();
  const dueAt = dueDate ? tokyoDateTimeInputToIso(dueDate) : undefined;
  const replyDueAt = replyDueDate ? tokyoDateTimeInputToIso(replyDueDate) : undefined;
  const rewriteSource = sharedMessage || initialRawMessage.trim();

  useEffect(() => {
    if (!user || !household) return;
    const attempt = loadStableCommandAttempt(user.id, household.id, logicalKey);
    if (!attempt || !['prepared', 'sending', 'unknown'].includes(attempt.state)) return;
    setLockedAttempt(attempt);
    const payload = attempt.payload;
    setTitle(typeof payload.shared_title === 'string' ? payload.shared_title : '');
    setMessage(String(payload.confirmed_message ?? payload.shared_message ?? ''));
    setReplyDueDate(toDateTimeLocal(payload.reply_due_at));
    setDueDate(toDateTimeLocal(payload.due_at));
    setRawInputId(typeof payload.raw_input_id === 'string' ? payload.raw_input_id : null);
    setPreviewing(true);
  }, [household, logicalKey, user]);

  async function rewriteMessageWithAi() {
    if (!rewriteSource || rewriting || lockedAttempt) return;
    setError(null);
    setRewriting(true);
    try {
      const proposal = await callEdgeFunction<{ raw_input_id: string; proposed_text: string }>(
        EDGE_FUNCTIONS.proposeAiDraft,
        { operation_id: newOperationId(), raw_text: rewriteSource, target_type: 'request' },
      );
      setMessage(proposal.proposed_text);
      setRawInputId(proposal.raw_input_id);
    } catch {
      setError('AIで言い換えられませんでした。自分で文面を整えて送れます。');
    } finally {
      setRewriting(false);
    }
  }

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    if (submitting || rewriting || (!sharedMessage && !lockedAttempt)) return;
    setError(null);
    if (!previewing) {
      setPreviewing(true);
      return;
    }

    setSubmitting(true);
    try {
      const endpoint = lockedAttempt?.endpoint ?? (rawInputId ? EDGE_FUNCTIONS.confirmRequestDraft : EDGE_FUNCTIONS.sendRequest);
      await runCommand(
        logicalKey,
        endpoint,
        (operationId) => lockedAttempt
          ? { ...lockedAttempt.payload }
          : {
              operation_id: operationId,
              recipient_user_id: recipientId,
              shared_title: sharedTitle,
              due_at: dueAt,
              reply_due_at: replyDueAt,
              ...(rawInputId
                ? { raw_input_id: rawInputId, confirmed_message: sharedMessage }
                : { shared_message: sharedMessage }),
            },
      );
      let status = `${recipientName}へのお願いを送りました。「送ったお願い」で返事を確認できます。`;
      if (pendingActionId) {
        try {
          await callEdgeFunction(EDGE_FUNCTIONS.cancelPendingAction, { pending_action_id: pendingActionId });
        } catch {
          status += ' LINEの下書きは残っている場合があります。';
        }
      }
      onSent(status);
    } catch (err) {
      const pendingAttempt = user && household ? loadStableCommandAttempt(user.id, household.id, logicalKey) : null;
      setLockedAttempt(pendingAttempt);
      setError(pendingAttempt || (err instanceof FamilyOpsApiError && err.outcome === 'unknown')
        ? '送信結果を確認できませんでした。同じ内容で送信結果を確認できます。'
        : 'お願いを送れませんでした。内容を確認して、もう一度お試しください。');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="stack-form card request-composer">
      {!previewing ? (
        <>
          <h2>お願いを作る</h2>
          <p>宛先は{recipientName}です。</p>
          <label>タイトル<input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="未入力なら「お願い」" /></label>
          <label>相手へ送る文面<textarea value={message} onChange={(e) => setMessage(e.target.value)} required disabled={rewriting} placeholder="今日18時のお迎えをお願いできますか？" /></label>
          {initialRawMessage && (
            <details>
              <summary>下書きの原文（相手には表示されません）</summary>
              <p className="line-preview-message">{initialRawMessage}</p>
            </details>
          )}
          <div>
            <button type="button" className="secondary-button" onClick={() => void rewriteMessageWithAi()} disabled={rewriting || !rewriteSource}>
              {rewriting ? 'AIが言い換え中…' : sharedMessage || !initialRawMessage ? 'AIでやわらかく言い換える' : '下書きの原文からAIで文面を作る'}
            </button>
            <p className="empty-hint">AIの言い換えは任意です。送る前に文面を編集できます。</p>
          </div>
          <div className="request-deadline-grid">
            <label>返事がほしい期限（任意・日本時間）<input type="datetime-local" value={replyDueDate} onChange={(e) => setReplyDueDate(e.target.value)} /></label>
            <label>作業期限（任意・日本時間）<input type="datetime-local" value={dueDate} onChange={(e) => setDueDate(e.target.value)} /></label>
          </div>
          <p className="request-scope">返事の期限を空欄にすると、送信時に自動で設定されます。今回だけのお願いです。</p>
          <button type="submit" disabled={rewriting || !sharedMessage}>送信内容を確認</button>
        </>
      ) : (
        <section className="line-sender-preview" aria-label="送信内容の確認">
          <h2>この内容で送りますか？</h2>
          <p>宛先　{recipientName}</p>
          <h3>{sharedTitle}</h3>
          <p className="line-preview-message">{sharedMessage}</p>
          <p className="line-preview-meta">
            {replyDueAt ? `返事がほしい期限　${formatDateTimeJa(replyDueAt)}（日本時間）` : '返事がほしい期限　送信時に自動で設定'}
          </p>
          <p className="line-preview-meta">
            {dueAt ? `作業期限　${formatDateTimeJa(dueAt)}（日本時間）` : '作業期限なし'} ／ 今回だけ
          </p>
          {lockedAttempt && <p className="request-scope" role="status">前回の送信結果を確認するため、内容を固定しています。</p>}
          <div className="modal-actions">
            {!lockedAttempt && <button type="button" className="secondary-button" onClick={() => setPreviewing(false)} disabled={submitting}>編集に戻る</button>}
            <button type="submit" disabled={submitting}>{submitting ? '確認中…' : lockedAttempt ? '送信結果を確認' : 'この内容でお願いを送る'}</button>
          </div>
        </section>
      )}
      {error && <p role="alert" className="error-text">{error}</p>}
    </form>
  );
}
