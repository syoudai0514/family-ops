import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { useAuth } from '../../app/AuthContext';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { formatDateTimeJa } from '../../lib/date';
import type { RequestRow } from '../../lib/types';

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
  const [showForm, setShowForm] = useState(false);

  if (loading) return <div className="app-shell">読み込み中…</div>;

  const incoming = requests.filter((r) => r.recipient_id === user?.id);
  const outgoing = requests.filter((r) => r.requester_id === user?.id);

  return (
    <div className="app-shell">
      <div className="today-header">
        <h1>お願い</h1>
        {partner && (
          <button type="button" onClick={() => setShowForm((v) => !v)}>
            {showForm ? '閉じる' : '+ お願いを送る'}
          </button>
        )}
      </div>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      {showForm && partner && (
        <SendRequestForm
          recipientId={partner.user_id}
          onSent={() => {
            setShowForm(false);
            refresh();
          }}
        />
      )}

      <section className="card">
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
      </section>

      <section className="card">
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
      </section>
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
        <strong>{request.shared_title}</strong> — {statusLabel(request.status)}
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

function SendRequestForm({ recipientId, onSent }: { recipientId: string; onSent: () => void }) {
  const [title, setTitle] = useState('');
  const [message, setMessage] = useState('');
  const [dueDate, setDueDate] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [rewriting, setRewriting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function rewriteMessageWithAi() {
    const rawText = message.trim();
    if (!rawText) {
      setError('言い換えたいメッセージを入力してください。');
      return;
    }
    setError(null);
    setRewriting(true);
    try {
      const proposal = await callEdgeFunction<{ proposed_text: string }>(EDGE_FUNCTIONS.proposeAiDraft, {
        operation_id: newOperationId(),
        raw_text: rawText,
        target_type: 'request',
      });
      setMessage(proposal.proposed_text);
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
      await callEdgeFunction(EDGE_FUNCTIONS.sendRequest, {
        operation_id: newOperationId(),
        recipient_user_id: recipientId,
        shared_title: title.trim(),
        shared_message: message.trim() || undefined,
        due_at: dueDate ? new Date(dueDate).toISOString() : undefined,
      });
      onSent();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '送信に失敗しました。');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="stack-form card">
      <label>
        タイトル
        <input value={title} onChange={(e) => setTitle(e.target.value)} required />
      </label>
      <label>
        メッセージ（任意）
        <textarea value={message} onChange={(e) => setMessage(e.target.value)} />
      </label>
      <button type="button" onClick={rewriteMessageWithAi} disabled={submitting || rewriting || message.trim().length === 0}>
        {rewriting ? 'AIが言い換え中…' : 'AIでやわらかく言い換える'}
      </button>
      <label>
        期限（任意）
        <input type="datetime-local" value={dueDate} onChange={(e) => setDueDate(e.target.value)} />
      </label>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      <button type="submit" disabled={submitting}>
        {submitting ? '送信中…' : '送る'}
      </button>
    </form>
  );
}
