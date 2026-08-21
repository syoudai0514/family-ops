import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from '../../app/AuthContext';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { formatDateTimeJa } from '../../lib/date';
import type { PendingAction, RequestRow } from '../../lib/types';

function useRequests(householdId: string | null) {
  const [requests, setRequests] = useState<RequestRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!householdId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    const { data, error: fetchError } = await supabase
      .from('requests')
      .select('*')
      .eq('household_id', householdId)
      .order('due_at', { ascending: true, nullsFirst: false });
    if (fetchError) setError(fetchError.message);
    else setRequests(data ?? []);
    setLoading(false);
  }, [householdId]);

  useEffect(() => {
    load();
  }, [load]);

  return { requests, loading, error, refresh: load };
}

export function Requests() {
  const { user } = useAuth();
  const { household, partner } = useHousehold();
  const { requests, loading, error, refresh } = useRequests(household?.id ?? null);
  const location = useLocation();
  const navigate = useNavigate();
  const pendingActionRawText = typeof (location.state as { pendingActionRawText?: unknown } | null)?.pendingActionRawText === 'string'
    ? (location.state as { pendingActionRawText: string }).pendingActionRawText
    : '';
  const pendingId = new URLSearchParams(location.search).get('pending');
  const [pendingAction, setPendingAction] = useState<PendingAction | null>(null);
  const [pendingLoadError, setPendingLoadError] = useState<string | null>(null);
  const [showForm, setShowForm] = useState(() => Boolean(pendingId) || new URLSearchParams(location.search).has('date') || Boolean(pendingActionRawText));

  useEffect(() => {
    let cancelled = false;
    if (!pendingId) {
      setPendingAction(null);
      return () => { cancelled = true; };
    }
    void (async () => {
      try {
        // The edge function is actor-scoped. Never trust the URL alone or
        // put the sender's private original text in a query parameter.
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

  const incoming = requests.filter((r) => r.recipient_id === user?.id);
  const outgoing = requests.filter((r) => r.requester_id === user?.id);

  return (
    <div className="app-shell">
      <div className="today-header">
        <h1>お願い</h1>
        {partner && (
          <button type="button" onClick={() => {
            setShowForm((v) => !v);
            if (showForm) clearPrivatePrefill();
          }}>
            {showForm ? '閉じる' : '+ お願いを送る'}
          </button>
        )}
      </div>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      {pendingLoadError && <p role="alert" className="error-text">{pendingLoadError}</p>}
      {showForm && partner && (
        <SendRequestForm
          recipientId={partner.user_id}
          initialRawMessage={String(pendingAction?.normalized_payload.raw_text ?? pendingActionRawText)}
          initialMessage={String(pendingAction?.normalized_payload.shared_message ?? '')}
          initialTitle={String(pendingAction?.normalized_payload.title ?? '')}
          initialDueDate={pendingAction ? toDateTimeLocal(pendingAction.normalized_payload.due_at) : ''}
          pendingActionId={pendingAction?.id ?? null}
          onSent={() => {
            setShowForm(false);
            clearPrivatePrefill();
            refresh();
          }}
        />
      )}

      {incoming.length > 0 && <section className="card">
        <h2>受け取ったお願い</h2>
        {incoming.length === 0 ? (
          <p className="empty-hint">なし</p>
        ) : (
          <ul className="request-list">
            {incoming.map((r) => (
              <IncomingRequestRow key={r.id} request={r} onChanged={refresh} />
            ))}
          </ul>
        )}
      </section>}

      {outgoing.length > 0 && <section className="card">
        <h2>送ったお願い</h2>
        {outgoing.length === 0 ? (
          <p className="empty-hint">なし</p>
        ) : (
          <ul className="request-list">
            {outgoing.map((r) => (
              <OutgoingRequestRow key={r.id} request={r} onChanged={refresh} />
            ))}
          </ul>
        )}
      </section>}
    </div>
  );
}

function statusLabel(status: RequestRow['status']): string {
  switch (status) {
    case 'pending':
      return '保留中';
    case 'accepted':
      return '引き受け済み';
    case 'declined':
      return '却下';
    case 'completed':
      return '完了';
    case 'cancelled':
      return 'キャンセル済み';
    default:
      return status;
  }
}

function IncomingRequestRow({ request, onChanged }: { request: RequestRow; onChanged: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function respond(kind: 'accept' | 'decline') {
    setBusy(true);
    setError(null);
    try {
      const functionName = kind === 'accept' && request.assignment_task_instance_id
        ? EDGE_FUNCTIONS.acceptAssignmentChangeRequest
        : kind === 'accept' ? EDGE_FUNCTIONS.acceptRequest : EDGE_FUNCTIONS.declineRequest;
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
        <strong>{request.shared_title}</strong> — {request.assignment_task_instance_id ? `${request.assignment_scope === 'this_week' ? '今週だけ' : '今回だけ'}の担当変更` : statusLabel(request.status)}
        {request.shared_message && <p>{request.shared_message}</p>}
        {request.due_at && <span className="task-item-meta">期限: {formatDateTimeJa(request.due_at)}</span>}
      </div>
      {request.status === 'pending' && (
        <div className="task-item-actions">
          <button type="button" disabled={busy} onClick={() => respond('accept')}>
            引き受ける
          </button>
          <button type="button" disabled={busy} onClick={() => respond('decline')}>
            断る
          </button>
        </div>
      )}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </li>
  );
}

function OutgoingRequestRow({ request, onChanged }: { request: RequestRow; onChanged: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function cancel() {
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.cancelRequest, {
        operation_id: newOperationId(),
        request_id: request.id,
      });
      onChanged();
    } catch (err) {
      if (err instanceof FamilyOpsApiError && err.code === 'REQUEST_CANCEL_NOT_ALLOWED') {
        setError('すでに引き受けられているため、キャンセルできません。');
      } else {
        setError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。');
      }
    } finally {
      setBusy(false);
    }
  }

  return (
    <li className="request-item">
      <div>
        <strong>{request.shared_title}</strong> — {statusLabel(request.status)}
        {request.shared_message && <p>{request.shared_message}</p>}
        {request.due_at && <span className="task-item-meta">期限: {formatDateTimeJa(request.due_at)}</span>}
      </div>
      {request.status === 'pending' && (
        <div className="task-item-actions">
          <button type="button" disabled={busy} onClick={cancel}>
            キャンセル
          </button>
        </div>
      )}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </li>
  );
}

function toDateTimeLocal(value: unknown): string {
  if (typeof value !== 'string' || !value) return '';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  const parts = new Intl.DateTimeFormat('sv-SE', {
    timeZone: 'Asia/Tokyo', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(date).reduce<Record<string, string>>((result, part) => ({ ...result, [part.type]: part.value }), {});
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}`;
}

function SendRequestForm({ recipientId, initialRawMessage = '', initialMessage = '', initialTitle = '', initialDueDate = '', pendingActionId = null, onSent }: { recipientId: string; initialRawMessage?: string; initialMessage?: string; initialTitle?: string; initialDueDate?: string; pendingActionId?: string | null; onSent: () => void }) {
  const [title, setTitle] = useState(initialTitle);
  // This is navigation state from the sender's own pending action. It is not
  // persisted or sent to the recipient; only `message` is shared on submit.
  const [rawMessage, setRawMessage] = useState(initialRawMessage);
  const [message, setMessage] = useState(initialMessage);
  const [dueDate, setDueDate] = useState(initialDueDate);
  const [submitting, setSubmitting] = useState(false);
  const [rewriting, setRewriting] = useState(false);
  const [rawInputId, setRawInputId] = useState<string | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function rewriteMessageWithAi() {
    const rawText = rawMessage.trim();
    if (!rawText) {
      setError('言い換えたいメッセージを入力してください。');
      return;
    }
    setError(null);
    setRewriting(true);
    try {
      const proposal = await callEdgeFunction<{ raw_input_id: string; proposed_text: string }>(EDGE_FUNCTIONS.proposeAiDraft, {
        operation_id: newOperationId(),
        raw_text: rawText,
        target_type: 'request',
      });
      setMessage(proposal.proposed_text);
      setRawInputId(proposal.raw_input_id);
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : 'AIによる言い換えに失敗しました。');
    } finally {
      setRewriting(false);
    }
  }

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      if (!message.trim()) { setError('相手へ共有する文面を入力してください。'); return; }
      const payload = {
        operation_id: newOperationId(),
        recipient_user_id: recipientId,
        shared_title: title.trim() || 'お願い',
        due_at: dueDate ? new Date(dueDate).toISOString() : undefined,
      };
      if (rawInputId) {
        await callEdgeFunction(EDGE_FUNCTIONS.confirmRequestDraft, { ...payload, raw_input_id: rawInputId, confirmed_message: message.trim() });
      } else {
        await callEdgeFunction(EDGE_FUNCTIONS.sendRequest, { ...payload, shared_message: message.trim() });
      }
      // The draft is private until this explicit PWA send. Mark it cancelled
      // afterwards so a later tap on the old LINE confirmation cannot create
      // a duplicate request. Cancellation never notifies the partner.
      if (pendingActionId) await callEdgeFunction(EDGE_FUNCTIONS.cancelPendingAction, { pending_action_id: pendingActionId });
      onSent();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '送信に失敗しました。');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="stack-form card request-composer">
      <div className="composer-steps" aria-label="お願い作成の手順"><span className={!previewing ? 'active' : ''}>1 作成</span><span className={previewing ? 'active' : ''}>2 確認</span><span>3 送信</span></div>
      <p className="eyebrow">相手に見えるのは、確認した文面だけです</p>
      <label>
        タイトル
        <input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="未入力なら「お願い」" />
      </label>
      <label>
        まずはそのまま入力
        <textarea value={rawMessage} onChange={(e) => { setRawMessage(e.target.value); setRawInputId(null); }} placeholder="今日ちょっと遅くなるから、迎えをお願いしたい" />
      </label>
      <button type="button" className="secondary-button" onClick={rewriteMessageWithAi} disabled={submitting || rewriting || rawMessage.trim().length === 0}>
        {rewriting ? 'AIが言い換え中…' : 'AIでやわらかく言い換える'}
      </button>
      <label>
        相手へ送る文面（確認・編集できます）
        <textarea value={message} onChange={(e) => setMessage(e.target.value)} required placeholder="AIで言い換えるか、直接入力してください" />
      </label>
      <label>
        期限（任意）
        <input type="datetime-local" value={dueDate} onChange={(e) => setDueDate(e.target.value)} />
      </label>
      <p className="request-scope">📅 今回だけのお願いです。担当変更の「今週だけ」は週画面から選べます。</p>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      {!previewing ? <button type="button" disabled={submitting || !message.trim()} onClick={() => setPreviewing(true)}>送信内容を確認</button> : (
        <section className="line-sender-preview" aria-label="LINE送信プレビュー">
          <p className="line-preview-kicker">LINE · 送る側の確認</p>
          <h3>この内容で送りますか？</h3>
          <p className="line-preview-message">{message}</p>
          <p className="line-preview-meta">{dueDate ? new Date(dueDate).toLocaleString('ja-JP') : '期限なし'} / 今回だけ</p>
          <p className="empty-hint">送るまでは、相手に通知されません。</p>
          <div className="modal-actions"><button type="button" className="secondary-button" onClick={() => setPreviewing(false)} disabled={submitting}>編集</button><button type="submit" disabled={submitting}>{submitting ? '送信中…' : 'LINEで送る'}</button></div>
        </section>
      )}
    </form>
  );
}
