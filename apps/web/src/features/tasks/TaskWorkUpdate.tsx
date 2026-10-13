import { useEffect, useRef, useState, type FormEvent } from 'react';
import { useAuth } from '../../app/AuthContext';
import { useHousehold, type HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import { FamilyOpsApiError } from '../../lib/apiClient';
import { loadStableCommandAttempt } from '../../lib/commandAttempt';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import type { TaskInstance } from '../../lib/types';
import { useCommandAttempt } from '../../lib/useCommandAttempt';
import { supabase } from '../../lib/supabaseClient';
import { withTimeout } from '../../lib/withTimeout';
import { getTaskDisplay } from './taskDisplay';
import type { TaskWorkProgressRecord } from '../../lib/taskProgress';

type Props = {
  task: TaskInstance;
  members: HouseholdMemberWithProfile[];
  currentUserId?: string | null;
  onSaved: () => void | Promise<void>;
  onCancel?: () => void;
};

type ProgressPayload = {
  task_id: string;
  expected_revision: number;
  observed_note: string;
  work_done_note: string;
  remaining_note: string;
  next_step_note: string;
  share_with_household: boolean;
  ack_policy: 'none' | 'required';
  valid_until?: string | null;
};

function endOfTokyoDay() {
  const day = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Tokyo', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  return new Date(new Date(`${day}T00:00:00+09:00`).getTime() + 86_400_000).toISOString();
}

function dateTimeLocal(value: string | null | undefined) {
  if (!value) return '';
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return '';
  const pad = (number: number) => String(number).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export function TaskWorkUpdate(props: Props) {
  const { user } = useAuth();
  const { household } = useHousehold();
  if (!user || !household || user.id !== props.currentUserId || household.id !== props.task.household_id) return null;
  return <WorkUpdateForm key={`${household.id}:${user.id}:${props.task.id}`} {...props} userId={user.id} householdId={household.id} />;
}

function WorkUpdateForm({ task, members, onSaved, onCancel, userId, householdId }: Props & { userId: string; householdId: string }) {
  const runCommand = useCommandAttempt();
  const logicalKey = `task:${task.id}:work-progress`;
  const [draft, setDraft] = useState<ProgressPayload>(() => {
    const pending = loadStableCommandAttempt(userId, householdId, logicalKey);
    if (pending?.endpoint === EDGE_FUNCTIONS.recordTaskProgress && pending.payload.task_id === task.id) {
      return pending.payload as unknown as ProgressPayload;
    }
    return {
      task_id: task.id, expected_revision: task.revision ?? 1,
      observed_note: '', work_done_note: '', remaining_note: '', next_step_note: '',
      share_with_household: false, ack_policy: 'none',
    };
  });
  const [pendingPayload, setPendingPayload] = useState<ProgressPayload | null>(() => {
    const pending = loadStableCommandAttempt(userId, householdId, logicalKey);
    return pending?.endpoint === EDGE_FUNCTIONS.recordTaskProgress && pending.payload.task_id === task.id
      ? pending.payload as unknown as ProgressPayload : null;
  });
  const [busy, setBusy] = useState(false);
  const [expiryMode, setExpiryMode] = useState<'today' | 'custom' | 'manual'>(() => draft.share_with_household
    ? draft.valid_until ? 'custom' : 'manual' : 'today');
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  // The wrapper remounts on identity changes, so stale replies have no UI effect.
  const { user } = useAuth();
  const { household } = useHousehold();
  const liveIdentity = useRef({ userId: user?.id, householdId: household?.id });
  liveIdentity.current = { userId: user?.id, householdId: household?.id };

  function change<K extends keyof ProgressPayload>(key: K, value: ProgressPayload[K]) {
    setDraft(previous => ({ ...previous, [key]: value }));
  }

  async function save(event: FormEvent) {
    event.preventDefault();
    if (busy || saved) return;
    if (liveIdentity.current.userId !== userId || liveIdentity.current.householdId !== householdId) return;
    const payload = pendingPayload ?? {
      ...draft, expected_revision: task.revision ?? 1,
      observed_note: draft.observed_note.trim(), work_done_note: draft.work_done_note.trim(),
      remaining_note: draft.remaining_note.trim(), next_step_note: draft.next_step_note.trim(),
      ack_policy: draft.share_with_household ? draft.ack_policy : 'none',
      valid_until: draft.share_with_household ? expiryMode === 'today' ? endOfTokyoDay() : draft.valid_until ?? null : null,
    };
    if (![payload.observed_note, payload.work_done_note, payload.remaining_note, payload.next_step_note].some(Boolean)) {
      setError('見つけた状況、行ったこと、残りの作業のいずれかを入力してください。');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await runCommand(logicalKey, EDGE_FUNCTIONS.recordTaskProgress, operationId => ({ operation_id: operationId, ...payload, action: 'record_progress' }));
      if (!mounted.current || liveIdentity.current.userId !== userId || liveIdentity.current.householdId !== householdId) return;
      setSaved(true);
      setPendingPayload(null);
      try { await onSaved(); } catch { setError('記録は保存しました。最新の一覧を再読み込みしてください。'); }
    } catch (err) {
      if (!mounted.current || liveIdentity.current.userId !== userId || liveIdentity.current.householdId !== householdId) return;
      if (err instanceof FamilyOpsApiError && err.outcome === 'unknown') {
        setPendingPayload(payload);
        setError('保存結果を確認できませんでした。同じ内容で「もう一度確認」を押してください。');
      } else {
        setPendingPayload(null);
        setError(err instanceof FamilyOpsApiError ? err.message : '記録を保存できませんでした。');
      }
    } finally {
      if (mounted.current) setBusy(false);
    }
  }

  const disabled = busy || Boolean(pendingPayload) || saved;
  return <form className="task-waiting-editor task-work-update" onSubmit={save}>
    <strong>状況・引き継ぎを記録</strong>
    <p className="task-item-meta">{getTaskDisplay(task).displayTitle} · 対象日 {task.scheduled_date}</p>
    <WorkUpdateHistory task={task} members={members} />
    <strong>新しく追記する</strong>
    <p className="empty-hint">下の入力欄は新しい記録用です。保存済みの内容は上の「これまでの状況メモ」に表示します。</p>
    <label>見つけた状況（任意）<textarea rows={2} maxLength={2000} disabled={disabled} value={draft.observed_note} onChange={event => change('observed_note', event.target.value)} placeholder="例: 昨日の分がまだ洗えていなかった" /></label>
    <label>自分が行ったこと（任意）<textarea rows={2} maxLength={2000} disabled={disabled} value={draft.work_done_note} onChange={event => change('work_done_note', event.target.value)} placeholder="例: 朝の食器を追加し、洗浄を開始した" /></label>
    <label>今の状態・残りの作業（任意）<textarea rows={2} maxLength={2000} disabled={disabled} value={draft.remaining_note} onChange={event => change('remaining_note', event.target.value)} placeholder="例: 洗浄中。食器の取り出しはまだ" /></label>
    <label>次の作業への影響・伝えること（任意）<textarea rows={2} maxLength={2000} disabled={disabled} value={draft.next_step_note} onChange={event => change('next_step_note', event.target.value)} placeholder="例: 洗浄が終わってから食器を取り出してほしい" /></label>
    <label className="task-work-share-choice"><input type="checkbox" disabled={disabled} checked={draft.share_with_household} onChange={event => change('share_with_household', event.target.checked)} /> 家族に引き継ぎを送る</label>
    {draft.share_with_household && <label className="task-work-share-choice"><input type="checkbox" disabled={disabled} checked={draft.ack_policy === 'required'} onChange={event => change('ack_policy', event.target.checked ? 'required' : 'none')} /> 確認の返答が必要</label>}
    {draft.share_with_household && <>
      <label>引き継ぎを表示する期間<select disabled={disabled} value={expiryMode} onChange={event => {
        const mode = event.target.value as typeof expiryMode;
        setExpiryMode(mode);
        change('valid_until', mode === 'today' ? endOfTokyoDay() : null);
      }}><option value="today">今日中</option><option value="custom">日時を指定</option><option value="manual">この共有を終えるまで</option></select></label>
      {expiryMode === 'custom' && <label>引き継ぎの期限<input type="datetime-local" required disabled={disabled} value={dateTimeLocal(draft.valid_until)} onChange={event => change('valid_until', event.target.value ? new Date(event.target.value).toISOString() : null)} /></label>}
      <p className="empty-hint">状況が変わったら、共有の「この共有を終える」で終了できます。記録は履歴に残ります。</p>
    </>}
    <p className="empty-hint">メモを保存しても作業は完了になりません。作業そのものが済んだら「完了」、一部が済んだらチェック項目で記録してください。</p>
    {pendingPayload && <p role="status" className="empty-hint">保存結果を確認するまで、内容を保持しています。</p>}
    {error && <p role="alert" className="error-text">{error}</p>}
    {saved && <p role="status">記録を保存しました。</p>}
    <button type="submit" disabled={busy || saved}>{pendingPayload ? 'もう一度確認' : draft.share_with_household ? '記録して引き継ぎを送る' : '記録を保存'}</button>
    {onCancel && <button type="button" className="text-button" disabled={busy} onClick={onCancel}>閉じる</button>}
  </form>;
}

const HISTORY_FIELDS = [
  ['observed_note', '見つけた状況'], ['work_done_note', '行ったこと'],
  ['remaining_note', '今の状態・残り'], ['next_step_note', '次の作業へ'],
] as const;

function WorkUpdateHistory({ task, members }: Pick<Props, 'task' | 'members'>) {
  const [events, setEvents] = useState<TaskWorkProgressRecord[]>(task.latest_work_progress ?? []);
  const [error, setError] = useState(false);
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    let current = true;
    setEvents(task.latest_work_progress ?? []);
    setError(false);
    setLoading(true);
    void (async () => {
      try {
        const result = await withTimeout(supabase.from('task_events')
          .select('id,actor_id,created_at,payload').eq('household_id', task.household_id)
          .eq('task_instance_id', task.id).eq('event_type', 'work_progress_recorded')
          .order('created_at', { ascending: false }).limit(5), 12_000, '記録履歴を読み込めませんでした。');
        if (result.error) throw result.error;
        if (current) setEvents((result.data ?? []) as TaskWorkProgressRecord[]);
      } catch { if (current) setError(true); }
      finally { if (current) setLoading(false); }
    })();
    return () => { current = false; };
  }, [task.id, task.household_id, task.revision]);
  if (!events.length) return <p className="empty-hint" role={error ? 'alert' : 'status'}>{error ? '保存済みの状況メモを読み込めませんでした。入力内容が消えたとは限りません。閉じて開き直してください。' : loading ? '保存済みの状況メモを読み込み中…' : 'この作業には、まだ状況メモがありません。'}</p>;
  return <details className="task-progress-history" open>
    <summary>これまでの状況メモ（保存済み）</summary>
    {error && <p role="alert" className="empty-hint">過去の記録をすべて読み込めませんでした。保存済みの最新メモを表示しています。</p>}
    <ul className="subtask-list">{events.map(event => {
      const member = members.find(candidate => candidate.user_id === event.actor_id);
      const author = member?.family_role === 'papa' ? 'パパ' : member?.family_role === 'mama' ? 'ママ' : member?.profile?.display_name ?? '家族';
      const timestamp = new Date(event.created_at);
      const recordedAt = Number.isFinite(timestamp.getTime()) ? new Intl.DateTimeFormat('ja-JP', { timeZone: 'Asia/Tokyo', month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }).format(timestamp) : '';
      return <li key={event.id}>
        <p className="task-item-meta">{author} · 記録 {recordedAt}</p>
        {HISTORY_FIELDS.map(([key, label]) => typeof event.payload?.[key] === 'string' && event.payload[key] ? <p key={key}>{label}: {String(event.payload[key])}</p> : null)}
        <p className="task-item-meta">{event.payload?.share_with_household === true ? '家族への引き継ぎあり' : '状況メモとして保存（引き継ぎの送信なし）'}</p>
      </li>;
    })}</ul>
  </details>;
}
