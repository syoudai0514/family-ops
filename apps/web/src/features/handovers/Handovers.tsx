import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { useAuth } from '../../app/AuthContext';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { todayIsoDate } from '../../lib/date';
import { useRealtimeRefresh } from '../../lib/useRealtimeRefresh';
import type { Handover, HandoverPeriod } from '../../lib/types';

const HANDOVER_REALTIME_TABLES = ['handovers', 'handover_reads'];

const PERIOD_LABELS: Record<HandoverPeriod, string> = {
  morning: '朝',
  day: '日中',
  evening: '夜',
  other: 'その他',
};

function useHandovers(householdId: string | null, userId: string | null) {
  const [handovers, setHandovers] = useState<Handover[]>([]);
  const [readIds, setReadIds] = useState<Set<string>>(new Set());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!householdId || !userId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    const { data: handoverRows, error: handoverError } = await supabase
      .from('handovers')
      .select('*')
      .eq('household_id', householdId)
      .order('created_at', { ascending: false });
    if (handoverError) {
      setError(handoverError.message);
      setLoading(false);
      return;
    }
    const rows = handoverRows ?? [];
    setHandovers(rows);

    if (rows.length > 0) {
      const { data: readRows, error: readError } = await supabase
        .from('handover_reads')
        .select('handover_id')
        .eq('user_id', userId)
        .in(
          'handover_id',
          rows.map((r) => r.id),
        );
      if (readError) setError(readError.message);
      else setReadIds(new Set((readRows ?? []).map((r) => r.handover_id)));
    } else {
      setReadIds(new Set());
    }
    setLoading(false);
  }, [householdId, userId]);

  useEffect(() => {
    load();
  }, [load]);

  useRealtimeRefresh({ householdId, userId, onRemoteChange: load, tables: HANDOVER_REALTIME_TABLES });

  return { handovers, readIds, loading, error, refresh: load };
}

// WP4 — handover unread indicator. Standalone hook (no rendering) so it can
// be mounted from AppShell's nav without pulling in the rest of the
// Handovers screen. Counts handovers this user hasn't marked read yet, and
// stays live via the same realtime plumbing the Handovers screen itself
// uses, so the badge updates as soon as the partner posts a new handover or
// either of you marks one read on another device.
export function useUnreadHandoverCount(): number {
  const { user } = useAuth();
  const { household } = useHousehold();
  const householdId = household?.id ?? null;
  const userId = user?.id ?? null;
  const [unreadCount, setUnreadCount] = useState(0);

  const load = useCallback(async () => {
    if (!householdId || !userId) {
      setUnreadCount(0);
      return;
    }
    const { data: handoverRows, error: handoverError } = await supabase
      .from('handovers')
      .select('id')
      .eq('household_id', householdId);
    if (handoverError) return;
    const ids = (handoverRows ?? []).map((h) => h.id as string);
    if (ids.length === 0) {
      setUnreadCount(0);
      return;
    }
    const { data: readRows, error: readError } = await supabase
      .from('handover_reads')
      .select('handover_id')
      .eq('user_id', userId)
      .in('handover_id', ids);
    if (readError) return;
    const readIdSet = new Set((readRows ?? []).map((r) => r.handover_id as string));
    setUnreadCount(ids.filter((id) => !readIdSet.has(id)).length);
  }, [householdId, userId]);

  useEffect(() => {
    load();
  }, [load]);

  useRealtimeRefresh({ householdId, userId, onRemoteChange: load, tables: HANDOVER_REALTIME_TABLES });

  return unreadCount;
}

// Read receipts are marked via an explicit "既読にする" button rather than
// automatically on scroll/view — this keeps read state a deliberate user
// action (matches "read receipt" semantics: it should mean "I saw and
// acknowledge this", not just "this scrolled past on my screen"), and is
// far simpler/more testable than an intersection-observer approach.
export function Handovers() {
  const { user } = useAuth();
  const { household } = useHousehold();
  const { handovers, readIds, loading, error, refresh } = useHandovers(household?.id ?? null, user?.id ?? null);
  const [showForm, setShowForm] = useState(false);

  if (loading) return <div className="app-shell">読み込み中…</div>;

  return (
    <div className="app-shell">
      <div className="today-header">
        <h1>引き継ぎ</h1>
        <button type="button" onClick={() => setShowForm((v) => !v)}>
          {showForm ? '閉じる' : '+ 引き継ぎを書く'}
        </button>
      </div>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      {showForm && (
        <ComposeHandoverForm
          onCreated={() => {
            setShowForm(false);
            refresh();
          }}
        />
      )}

      <ul className="handover-list">
        {handovers.length === 0 && <li className="empty-hint">まだ引き継ぎはありません。</li>}
        {handovers.map((h) => (
          <HandoverRow key={h.id} handover={h} isRead={readIds.has(h.id)} onChanged={refresh} />
        ))}
      </ul>
    </div>
  );
}

function HandoverRow({ handover, isRead, onChanged }: { handover: Handover; isRead: boolean; onChanged: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function markRead() {
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.markHandoverRead, {
        operation_id: newOperationId(),
        handover_id: handover.id,
      });
      onChanged();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。');
    } finally {
      setBusy(false);
    }
  }

  return (
    <li className={isRead ? 'handover-item' : 'handover-item unread'}>
      <div>
        <span className="task-item-meta">
          {handover.occurred_on} · {PERIOD_LABELS[handover.period]}
          {handover.categories.length > 0 ? ` · ${handover.categories.join(', ')}` : ''}
        </span>
        <p>{handover.shared_text}</p>
      </div>
      {!isRead && (
        <button type="button" disabled={busy} onClick={markRead}>
          既読にする
        </button>
      )}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </li>
  );
}

function ComposeHandoverForm({ onCreated }: { onCreated: () => void }) {
  const [text, setText] = useState('');
  const [period, setPeriod] = useState<HandoverPeriod>('day');
  const [categoriesInput, setCategoriesInput] = useState('');
  const [occurredOn, setOccurredOn] = useState(todayIsoDate());
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      const categories = categoriesInput
        .split(',')
        .map((c) => c.trim())
        .filter((c) => c.length > 0);
      await callEdgeFunction(EDGE_FUNCTIONS.createHandover, {
        operation_id: newOperationId(),
        shared_text: text.trim(),
        period,
        categories,
        occurred_on: occurredOn,
      });
      onCreated();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '作成に失敗しました。');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="stack-form card">
      <label>
        内容
        <textarea value={text} onChange={(e) => setText(e.target.value)} required />
      </label>
      <label>
        時間帯
        <select value={period} onChange={(e) => setPeriod(e.target.value as HandoverPeriod)}>
          {(Object.keys(PERIOD_LABELS) as HandoverPeriod[]).map((p) => (
            <option key={p} value={p}>
              {PERIOD_LABELS[p]}
            </option>
          ))}
        </select>
      </label>
      <label>
        カテゴリ（カンマ区切り、任意）
        <input
          value={categoriesInput}
          onChange={(e) => setCategoriesInput(e.target.value)}
          placeholder="例: 保育園, 体調"
        />
      </label>
      <label>
        日付
        <input type="date" value={occurredOn} onChange={(e) => setOccurredOn(e.target.value)} required />
      </label>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      <button type="submit" disabled={submitting}>
        {submitting ? '送信中…' : '送信する'}
      </button>
    </form>
  );
}
