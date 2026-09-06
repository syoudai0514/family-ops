import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';

type CandidateKind = 'protected_change' | 'google_deleted' | 'possible_duplicate' | 'preparation_change';
type Resolution = 'accept_google' | 'keep_family' | 'same_event' | 'different_event' | 'cancel_family' | 'waiting_reschedule' | 'google_only_hidden' | 'apply' | 'keep';

type Review = {
  id: string;
  revision: number;
  candidate_kind: CandidateKind;
  family_event_title: string;
  family_event_all_day?: boolean;
  family_event_starts_at?: string | null;
  family_event_ends_at?: string | null;
  family_event_starts_on?: string | null;
  family_event_ends_on?: string | null;
  family_event_location_text?: string | null;
  google_title?: string | null;
  google_all_day?: boolean;
  google_starts_at?: string | null;
  google_ends_at?: string | null;
  google_starts_on?: string | null;
  google_ends_on?: string | null;
  google_location_text?: string | null;
  changed_fields?: string[];
  task_title?: string;
  old_scheduled_date?: string;
  proposed_scheduled_date?: string;
  old_due_at?: string | null;
  proposed_due_at?: string | null;
};

function scheduleLabel(allDay = false, startAt?: string | null, endAt?: string | null, startOn?: string | null, endOn?: string | null) {
  if (allDay) return startOn === endOn ? (startOn ?? '日付なし') : `${startOn ?? '?'} 〜 ${endOn ?? '?'}`;
  const fmt = (value?: string | null) => value ? new Intl.DateTimeFormat('ja-JP', {
    timeZone: 'Asia/Tokyo', month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(new Date(value)) : '時刻なし';
  return `${fmt(startAt)} 〜 ${fmt(endAt)}`;
}

function prepSchedule(date?: string, dueAt?: string | null) {
  if (!date) return '日付なし';
  if (!dueAt) return date;
  return `${date} · ${new Intl.DateTimeFormat('ja-JP', { timeZone: 'Asia/Tokyo', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(dueAt))}`;
}

function errorMessage(error: unknown) {
  if (error instanceof FamilyOpsApiError && error.code === 'CONFLICT') return '内容が更新されました。最新の候補を読み直してください。';
  if (error instanceof Error) return error.message;
  return '操作に失敗しました。もう一度お試しください。';
}

function ReviewCard({ review, busy, onResolve }: { review: Review; busy: boolean; onResolve: (review: Review, resolution: Resolution) => void }) {
  if (review.candidate_kind === 'preparation_change') {
    return <article className="card">
      <p className="eyebrow">関連する準備の変更候補</p>
      <h2>{review.task_title ?? '準備ToDo'}</h2>
      <p>「{review.family_event_title}」の日時が変わりました。準備は自動で動かしていません。</p>
      <dl>
        <dt>現在</dt><dd>{prepSchedule(review.old_scheduled_date, review.old_due_at)}</dd>
        <dt>変更候補</dt><dd>{prepSchedule(review.proposed_scheduled_date, review.proposed_due_at)}</dd>
      </dl>
      <div className="button-row">
        <button type="button" className="secondary-button" disabled={busy} onClick={() => onResolve(review, 'keep')}>このまま</button>
        <button type="button" className="primary-button" disabled={busy} onClick={() => onResolve(review, 'apply')}>変更を反映</button>
      </div>
    </article>;
  }

  const currentSchedule = scheduleLabel(review.family_event_all_day, review.family_event_starts_at, review.family_event_ends_at, review.family_event_starts_on, review.family_event_ends_on);
  const googleSchedule = scheduleLabel(review.google_all_day, review.google_starts_at, review.google_ends_at, review.google_starts_on, review.google_ends_on);

  if (review.candidate_kind === 'possible_duplicate') {
    return <article className="card">
      <p className="eyebrow">重複候補</p><h2>{review.family_event_title}</h2>
      <p>Googleにも同じ日時・同じ名前の予定があります。自動では統合しません。</p>
      <dl><dt>おうちノート</dt><dd>{currentSchedule}</dd><dt>Google</dt><dd>{review.google_title ?? '無題'} · {googleSchedule}</dd></dl>
      <div className="button-row">
        <button type="button" className="secondary-button" disabled={busy} onClick={() => onResolve(review, 'different_event')}>別の予定</button>
        <button type="button" className="primary-button" disabled={busy} onClick={() => onResolve(review, 'same_event')}>同じ予定</button>
      </div>
    </article>;
  }

  if (review.candidate_kind === 'google_deleted') {
    return <article className="card">
      <p className="eyebrow">Googleから消えた予定</p><h2>{review.family_event_title}</h2>
      <p>Googleでは削除されています。家庭予定をどう扱うか選んでください。</p>
      <div className="button-row">
        <button type="button" disabled={busy} onClick={() => onResolve(review, 'cancel_family')}>予定を中止</button>
        <button type="button" className="secondary-button" disabled={busy} onClick={() => onResolve(review, 'waiting_reschedule')}>日程変更待ち</button>
        <button type="button" className="secondary-button" disabled={busy} onClick={() => onResolve(review, 'google_only_hidden')}>Googleのみ非表示</button>
      </div>
    </article>;
  }

  const changedFields = review.changed_fields ?? [];
  return <article className="card">
    <p className="eyebrow">Googleで変更あり</p><h2>{review.family_event_title}</h2>
    <p>人が確認した内容は自動で上書きしていません。差分を確認してください。</p>
    {changedFields.includes('title') && <p><strong>名前</strong><br />おうちノート: {review.family_event_title}<br />Google: {review.google_title ?? '無題'}</p>}
    {changedFields.includes('schedule') && <p><strong>日時</strong><br />おうちノート: {currentSchedule}<br />Google: {googleSchedule}</p>}
    {changedFields.includes('location') && <p><strong>場所</strong><br />おうちノート: {review.family_event_location_text ?? '未設定'}<br />Google: {review.google_location_text ?? '未設定'}</p>}
    <div className="button-row">
      <button type="button" className="secondary-button" disabled={busy} onClick={() => onResolve(review, 'keep_family')}>おうちノートのまま</button>
      <button type="button" className="primary-button" disabled={busy} onClick={() => onResolve(review, 'accept_google')}>Googleの変更を反映</button>
    </div>
  </article>;
}

export function GoogleEventReviewPage() {
  const [reviews, setReviews] = useState<Review[]>([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function load() {
    setLoading(true); setError(null);
    try { setReviews(await callEdgeFunction<Review[]>(EDGE_FUNCTIONS.listGoogleEventReviews, {})); }
    catch (e) { setError(errorMessage(e)); }
    finally { setLoading(false); }
  }
  useEffect(() => { void load(); }, []);

  async function resolve(review: Review, resolution: Resolution) {
    setBusyId(review.id); setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.resolveGoogleEventReview, {
        operationId: newOperationId(), candidateId: review.id, candidateKind: review.candidate_kind,
        expectedRevision: review.revision, resolution,
      });
      await load();
    } catch (e) { setError(errorMessage(e)); }
    finally { setBusyId(null); }
  }

  return <main className="app-shell planning-page">
    <div className="section-heading"><div><p className="eyebrow">Googleカレンダー</p><h1>予定の変更を確認</h1></div><Link className="secondary-button" to="/month">月表示へ戻る</Link></div>
    <p className="empty-hint">Google側の変更・削除・重複と、予定変更に伴う準備ToDoの候補を確認します。人が確定した内容を勝手に上書き・削除・移動・マージしません。</p>
    {error && <p role="alert" className="error-text">{error}</p>}
    {loading ? <p role="status">読み込み中…</p> : reviews.length === 0 ? <div className="card"><p>確認が必要なGoogle予定はありません。</p></div> : reviews.map((review) => <ReviewCard key={`${review.candidate_kind}:${review.id}`} review={review} busy={busyId === review.id} onResolve={resolve} />)}
  </main>;
}
