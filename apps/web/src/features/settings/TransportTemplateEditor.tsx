import { useCallback, useEffect, useMemo, useState } from 'react';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { WEEKDAYS } from '../../lib/weekdays';
import './TransportTemplateEditor.css';

type TemplateDay = { weekday: number; dropoff_user_id: string | null; pickup_user_id: string | null; dropoff_local_time: string | null; pickup_local_time: string | null };
type TransportTemplate = { id: string; valid_from: string; valid_to: string | null; revision: number; days: TemplateDay[] };
type ProtectedConflict = { task_id: string; date: string; leg: 'dropoff' | 'pickup'; planned_assignee_user_id: string | null; assignment_source: string | null };
type ConflictReview = { id: string; revision: number; status: 'pending' | 'kept' | 'needs_review'; my_response: 'keep' | 'review' | null; items: Array<{ task_id: string; date: string; leg: 'dropoff' | 'pickup' }> };
type TransportScheduleRead = { templates: TransportTemplate[]; overrides: Array<{ id: string; occurrence_date: string }> };
type DraftDay = { weekday: number; dropoffUserId: string; pickupUserId: string; dropoffLocalTime: string; pickupLocalTime: string };

function todayIso() {
  return new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Tokyo', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
}
function defaultDays(source?: TransportTemplate): DraftDay[] {
  return WEEKDAYS.map(({ value }) => {
    const existing = source?.days.find((day) => day.weekday === value);
    return { weekday: value, dropoffUserId: existing?.dropoff_user_id ?? '', pickupUserId: existing?.pickup_user_id ?? '', dropoffLocalTime: existing?.dropoff_local_time?.slice(0, 5) ?? '08:00', pickupLocalTime: existing?.pickup_local_time?.slice(0, 5) ?? '17:30' };
  });
}
function periodLabel(template: TransportTemplate) {
  const short = (date: string) => { const [, month, day] = date.split('-'); return `${Number(month)}/${Number(day)}`; };
  return `${short(template.valid_from)} ～ ${template.valid_to ? short(template.valid_to) : '期限未定'}`;
}

export function TransportTemplateEditor({ members }: { members: HouseholdMemberWithProfile[] }) {
  const [templates, setTemplates] = useState<TransportTemplate[]>([]);
  const [validFrom, setValidFrom] = useState(todayIso());
  const [days, setDays] = useState<DraftDay[]>(() => defaultDays());
  const [reviews, setReviews] = useState<ConflictReview[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [busyReviewId, setBusyReviewId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [protectedConflicts, setProtectedConflicts] = useState<ProtectedConflict[]>([]);
  const latest = useMemo(() => [...templates].sort((a, b) => b.valid_from.localeCompare(a.valid_from))[0], [templates]);

  const load = useCallback(async () => {
    setLoading(true); setError(null);
    try {
      const [schedule, conflictReviews] = await Promise.all([
        callEdgeFunction<TransportScheduleRead>(EDGE_FUNCTIONS.transportSchedule, { action: 'read' }),
        callEdgeFunction<ConflictReview[]>(EDGE_FUNCTIONS.transportSchedule, { action: 'list_conflict_reviews' }),
      ]);
      const loaded = schedule.templates ?? [];
      setTemplates(loaded); setReviews(conflictReviews ?? []);
      setDays(defaultDays([...loaded].sort((a, b) => b.valid_from.localeCompare(a.valid_from))[0]));
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '送り迎えの定例を読み込めませんでした。');
    } finally { setLoading(false); }
  }, []);
  useEffect(() => { void load(); }, [load]);

  function patchDay(weekday: number, patch: Partial<DraftDay>) {
    setDays((current) => current.map((day) => day.weekday === weekday ? { ...day, ...patch } : day));
  }

  async function save() {
    setSaving(true); setError(null); setNotice(null); setProtectedConflicts([]);
    try {
      const result = await callEdgeFunction<{ protected_conflicts?: ProtectedConflict[] }>(EDGE_FUNCTIONS.transportSchedule, {
        action: 'save_template', operation_id: newOperationId(), valid_from: validFrom,
        days: days.map((day) => ({ weekday: day.weekday, dropoff_user_id: day.dropoffUserId || null, pickup_user_id: day.pickupUserId || null, dropoff_local_time: day.dropoffUserId ? day.dropoffLocalTime || null : null, pickup_local_time: day.pickupUserId ? day.pickupLocalTime || null : null })),
      });
      const conflicts = result.protected_conflicts ?? [];
      setProtectedConflicts(conflicts);
      setNotice(conflicts.length > 0
        ? `新しい生活パターンを保存しました。個別合意${conflicts.length}件は変更せず、パパ・ママ双方の維持確認を待っています。`
        : '新しい生活パターンを保存しました。直前の期間は自動で前日までに調整されます。');
      await load();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '送り迎えの定例を保存できませんでした。');
    } finally { setSaving(false); }
  }

  async function respondReview(review: ConflictReview, response: 'keep' | 'review') {
    setBusyReviewId(review.id); setError(null);
    try {
      const result = await callEdgeFunction<{ status: string; q51_state?: string | null }>(EDGE_FUNCTIONS.transportSchedule, {
        action: 'respond_conflict_review', operation_id: newOperationId(), review_id: review.id,
        expected_revision: review.revision, response,
      });
      setNotice(result.status === 'needs_review'
        ? '双方の回答を確認しました。元の個別合意を維持したまま担当調整中にしました。'
        : result.status === 'kept' ? '双方が「維持する」で一致しました。個別合意を維持します。' : '回答を保存しました。もう一方の確認を待っています。');
      await load();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '維持確認を保存できませんでした。最新状態を読み直してください。');
    } finally { setBusyReviewId(null); }
  }

  return <section className="card transport-template-card" aria-labelledby="transport-template-title">
    <div className="section-heading"><div><h2 id="transport-template-title">送り・お迎え</h2><p className="empty-hint">1週間の担当を生活パターンとしてまとめて保存します。終了日は通常入力しなくて大丈夫です。</p></div></div>
    {loading ? <p role="status">読み込み中…</p> : <>
      {reviews.map((review) => <section key={review.id} className="card transport-protected-conflicts" aria-label="個別合意の維持確認">
        <p className="eyebrow">双方の確認が必要</p><h3>個別に合意済みの予定を維持しますか？</h3>
        <p>新しい生活パターンでは上書きしていません。パパ・ママの両方が確認するまで元の個別合意を有効にします。</p>
        <ul>{review.items.map((item) => <li key={`${item.task_id}:${item.leg}`}>{item.date} · {item.leg === 'dropoff' ? '送り' : 'お迎え'}</li>)}</ul>
        {review.my_response && <p className="task-item-meta">自分の回答: {review.my_response === 'keep' ? '維持する' : '見直す'}</p>}
        <div className="button-row">
          <button type="button" className="secondary-button" disabled={busyReviewId === review.id} onClick={() => respondReview(review, 'keep')}>維持する</button>
          <button type="button" disabled={busyReviewId === review.id} onClick={() => respondReview(review, 'review')}>見直す</button>
        </div>
      </section>)}
      {templates.length > 0 && <div className="transport-template-timeline" aria-label="生活パターンの期間"><h3>生活パターンの履歴</h3><ol>{[...templates].sort((a, b) => a.valid_from.localeCompare(b.valid_from)).map((template) => <li key={template.id} className={template.id === latest?.id ? 'current' : ''}><span>{periodLabel(template)}</span>{template.id === latest?.id && template.valid_to === null && <b>現在</b>}</li>)}</ol></div>}
      <label className="transport-template-start">この生活パターンを始める日<input type="date" aria-label="この生活パターンを始める日" value={validFrom} onChange={(event) => setValidFrom(event.target.value)} /><small>期限未定で保存され、次の生活パターンを追加すると直前分が自動で閉じます。</small></label>
      <div className="transport-week-matrix" role="table" aria-label="1週間の送り迎え担当">
        <div className="transport-week-head" role="columnheader">曜日</div><div className="transport-week-head" role="columnheader">送り</div><div className="transport-week-head" role="columnheader">お迎え</div>
        {WEEKDAYS.map((weekday) => { const row = days.find((day) => day.weekday === weekday.value); if (!row) return null; return <div className="transport-week-row" role="row" key={weekday.value}>
          <strong role="cell">{weekday.label}</strong>
          <div role="cell" className="transport-week-cell"><select aria-label={`${weekday.label}曜日の送り担当`} value={row.dropoffUserId} onChange={(event) => patchDay(weekday.value, { dropoffUserId: event.target.value })}><option value="">なし</option>{members.map((member) => <option key={member.user_id} value={member.user_id}>{member.profile?.display_name ?? '家族'}</option>)}</select>{row.dropoffUserId && <input type="time" aria-label={`${weekday.label}曜日の送り時刻`} value={row.dropoffLocalTime} onChange={(event) => patchDay(weekday.value, { dropoffLocalTime: event.target.value })} />}</div>
          <div role="cell" className="transport-week-cell"><select aria-label={`${weekday.label}曜日のお迎え担当`} value={row.pickupUserId} onChange={(event) => patchDay(weekday.value, { pickupUserId: event.target.value })}><option value="">なし</option>{members.map((member) => <option key={member.user_id} value={member.user_id}>{member.profile?.display_name ?? '家族'}</option>)}</select>{row.pickupUserId && <input type="time" aria-label={`${weekday.label}曜日のお迎え時刻`} value={row.pickupLocalTime} onChange={(event) => patchDay(weekday.value, { pickupLocalTime: event.target.value })} />}</div>
        </div>; })}
      </div>
      <button type="button" onClick={save} disabled={saving || !validFrom}>{saving ? '保存中…' : 'この日から新しい生活パターンとして保存'}</button>
    </>}
    {notice && <p role="status" className="success-text">{notice}</p>}
    {protectedConflicts.length > 0 && <details className="transport-protected-conflicts"><summary>維持中の個別確定予定 {protectedConflicts.length}件</summary><ul>{protectedConflicts.map((conflict) => <li key={`${conflict.task_id}:${conflict.leg}`}>{conflict.date} · {conflict.leg === 'dropoff' ? '送り' : 'お迎え'}</li>)}</ul><p className="empty-hint">ルール変更では上書きしていません。上の双方確認で「維持する / 見直す」を回答してください。</p></details>}
    {error && <p role="alert" className="error-text">{error}</p>}
  </section>;
}
