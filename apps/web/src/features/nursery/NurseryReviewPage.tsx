import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';

type JsonObject = Record<string, unknown>;

type NurseryContext = {
  id: string;
  school_display_name: string;
  class_display_name: string | null;
  child_display_name: string;
};

type NurseryReviewItem = {
  id: string;
  candidate_key: string;
  origin: 'source_explicit' | 'ai_inference';
  item_kind: 'preparation' | 'task' | 'timetable' | 'shared_info' | 'submission' | 'url' | 'recurrence' | 'exception';
  classification: 'recommended' | 'other' | null;
  source_document_id: string;
  source_page: number;
  source_locator: string | null;
  proposed_value: JsonObject;
  confidence_band: 'high' | 'medium' | 'low';
  previous_confirmed_item_id: string | null;
};

type NurseryReview = {
  intake_id: string;
  status: 'needs_clarification' | 'review_ready' | 'confirmed' | string;
  revision: number;
  child_school_context_id: string | null;
  context_confidence: 'high' | 'medium' | 'low' | null;
  ambiguity_fields: string[];
  source_document_id: string | null;
  raw_available: boolean;
  source_image_url: string | null;
  available_contexts: NurseryContext[];
  items: NurseryReviewItem[];
};

type PendingReview = {
  intake_id: string;
  status: 'needs_clarification' | 'review_ready';
  revision: number;
  received_at: string;
  context_confidence: 'high' | 'medium' | 'low' | null;
  ambiguity_fields: string[];
  item_count: number;
};

type DraftItem = {
  selected: boolean;
  value: JsonObject;
  advancedJson: string;
  jsonError: string | null;
};

const ITEM_KIND_LABELS: Record<NurseryReviewItem['item_kind'], string> = {
  preparation: '準備するもの',
  task: 'ToDo',
  timetable: '予定',
  shared_info: '家族への共有',
  submission: '提出物',
  url: 'URL / QR / 提出先',
  recurrence: '定例予定',
  exception: 'この日だけの変更',
};

const FIELD_LABELS: Record<string, string> = {
  title: '内容',
  text: '共有内容',
  due_date: '期限・日付',
  date: '日付',
  location: '場所',
  details: '詳細',
  url: '実行先URL',
  add_to_calendar: 'Google Calendarにも表示する',
  effective_from: '開始日',
  effective_to: '終了日',
  occurrence_date: '対象日',
};

const AMBIGUITY_LABELS: Record<string, string> = {
  nursery: '園',
  child: '子ども',
  class: 'クラス',
  date: '日付',
  document_group: '同じ資料かどうか',
};

function errorMessage(error: unknown): string {
  if (error instanceof FamilyOpsApiError) {
    if (error.code === 'CONFLICT') return 'ほかの画面で内容が更新されました。最新内容を読み直してください。';
    return error.message;
  }
  return '操作に失敗しました。もう一度お試しください。';
}

function primitiveInputType(key: string): 'date' | 'url' | 'text' {
  if (key === 'date' || key === 'due_date' || key === 'effective_from' || key === 'effective_to' || key === 'occurrence_date') return 'date';
  if (key === 'url') return 'url';
  return 'text';
}

function originLabel(origin: NurseryReviewItem['origin']) {
  return origin === 'source_explicit' ? 'おたよりに明記' : 'AIの推測';
}

function confidenceLabel(confidence: NurseryReviewItem['confidence_band']) {
  if (confidence === 'high') return '確度 高';
  if (confidence === 'medium') return '確度 中';
  return '確度 低';
}

function contextLabel(context: NurseryContext) {
  return [context.child_display_name, context.school_display_name, context.class_display_name].filter(Boolean).join('・');
}

function makeDraft(item: NurseryReviewItem): DraftItem {
  const value: JsonObject = { ...item.proposed_value };
  // Q104: Calendar is optional and must never be selected by image inference.
  // The human review surface starts OFF and can explicitly choose ON.
  if (item.item_kind === 'submission') value.add_to_calendar = false;
  return {
    selected: item.classification !== 'other',
    value,
    advancedJson: JSON.stringify(value, null, 2),
    jsonError: null,
  };
}

function buildDrafts(items: NurseryReviewItem[]): Record<string, DraftItem> {
  return Object.fromEntries(items.map((item) => [item.id, makeDraft(item)]));
}

function ReviewItemEditor({
  item,
  draft,
  onChange,
}: {
  item: NurseryReviewItem;
  draft: DraftItem;
  onChange: (next: DraftItem) => void;
}) {
  const primitiveFields = Object.entries(draft.value).filter(([, value]) => value === null || ['string', 'number', 'boolean'].includes(typeof value));

  function updatePrimitive(key: string, raw: string, original: unknown) {
    let value: unknown = raw;
    if (typeof original === 'number') value = Number(raw);
    if (typeof original === 'boolean') value = raw === 'true';
    const nextValue = { ...draft.value, [key]: value };
    onChange({ ...draft, value: nextValue, advancedJson: JSON.stringify(nextValue, null, 2), jsonError: null });
  }

  function applyAdvancedJson() {
    try {
      const parsed = JSON.parse(draft.advancedJson) as unknown;
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('object required');
      onChange({ ...draft, value: parsed as JsonObject, jsonError: null });
    } catch {
      onChange({ ...draft, jsonError: '詳細内容の形式を確認してください。' });
    }
  }

  return (
    <article className="card nursery-review-item">
      <div className="section-heading">
        <div>
          <p className="eyebrow">{originLabel(item.origin)} · {confidenceLabel(item.confidence_band)}</p>
          <h2>{ITEM_KIND_LABELS[item.item_kind]}</h2>
        </div>
        <label className="checkbox-label">
          <input
            type="checkbox"
            checked={draft.selected}
            onChange={(event) => onChange({ ...draft, selected: event.target.checked })}
          />
          登録する
        </label>
      </div>

      <p className="task-item-meta">
        出典: 画像 {item.source_page}ページ目{item.source_locator ? ` · ${item.source_locator}` : ''}
      </p>
      {item.classification === 'recommended' && <p className="status-chip">登録おすすめ</p>}
      {item.classification === 'other' && <p className="status-chip">その他の予定 — 消さずに確認できます</p>}
      {item.previous_confirmed_item_id && (
        <p className="empty-hint">前回確定した内容があります。これは上書きではなく差分候補です。</p>
      )}

      <div className="form-grid">
        {primitiveFields.map(([key, value]) => (
          <label key={key}>
            <span>{FIELD_LABELS[key] ?? key}</span>
            {typeof value === 'boolean' ? (
              <select value={String(value)} onChange={(event) => updatePrimitive(key, event.target.value, value)}>
                <option value="true">はい</option>
                <option value="false">いいえ</option>
              </select>
            ) : (
              <input
                type={primitiveInputType(key)}
                value={value == null ? '' : String(value)}
                onChange={(event) => updatePrimitive(key, event.target.value, value)}
              />
            )}
          </label>
        ))}
      </div>

      <details>
        <summary>詳細内容も編集する</summary>
        <label>
          <span>構造化された詳細</span>
          <textarea
            rows={7}
            value={draft.advancedJson}
            onChange={(event) => onChange({ ...draft, advancedJson: event.target.value, jsonError: null })}
          />
        </label>
        <button type="button" className="secondary-button" onClick={applyAdvancedJson}>詳細編集を反映</button>
        {draft.jsonError && <p role="alert" className="error-text">{draft.jsonError}</p>}
      </details>
    </article>
  );
}

export function NurseryReviewPage() {
  const { intakeId } = useParams<{ intakeId?: string }>();
  const navigate = useNavigate();
  const [pending, setPending] = useState<PendingReview[]>([]);
  const [review, setReview] = useState<NurseryReview | null>(null);
  const [drafts, setDrafts] = useState<Record<string, DraftItem>>({});
  const [selectedContextId, setSelectedContextId] = useState('');
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  async function loadList() {
    setLoading(true);
    setError(null);
    try {
      const rows = await callEdgeFunction<PendingReview[]>(EDGE_FUNCTIONS.listNurseryReviews, {});
      setPending(rows);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setLoading(false);
    }
  }

  async function loadReview(id: string) {
    setLoading(true);
    setError(null);
    try {
      const result = await callEdgeFunction<NurseryReview>(EDGE_FUNCTIONS.getNurseryReview, { intake_id: id });
      setReview(result);
      setDrafts(buildDrafts(result.items));
      setSelectedContextId(result.child_school_context_id ?? result.available_contexts[0]?.id ?? '');
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    if (intakeId) void loadReview(intakeId);
    else void loadList();
    // Route id is the only reload key. load functions intentionally stay local.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [intakeId]);

  const selectedCount = useMemo(() => Object.values(drafts).filter((draft) => draft.selected).length, [drafts]);
  const hasDraftJsonError = useMemo(() => Object.values(drafts).some((draft) => Boolean(draft.jsonError)), [drafts]);

  async function resolveAmbiguity() {
    if (!review) return;
    if (!selectedContextId) {
      setError('園・子ども・クラスを選んでください。');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.resolveNurseryAmbiguity, {
        intake_id: review.intake_id,
        expected_revision: review.revision,
        child_school_context_id: selectedContextId,
        resolved_fields: review.ambiguity_fields,
      });
      await loadReview(review.intake_id);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  async function confirmReview() {
    if (!review) return;
    if (review.ambiguity_fields.length > 0 || !review.child_school_context_id) {
      setError('曖昧な項目を先に確認してください。');
      return;
    }
    if (hasDraftJsonError) {
      setError('詳細編集のエラーを直してください。');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.confirmNurseryReview, {
        operation_id: newOperationId(),
        intake_id: review.intake_id,
        expected_revision: review.revision,
        selected_items: review.items
          .filter((item) => drafts[item.id]?.selected)
          .map((item) => ({ review_item_id: item.id, confirmed_value: drafts[item.id].value })),
      });
      setDone(true);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  async function deleteSourceImage() {
    if (!review || !review.raw_available) return;
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.deleteNurserySourceImage, {
        intake_id: review.intake_id,
        expected_revision: review.revision,
      });
      await loadReview(review.intake_id);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  if (loading) return <main className="app-shell"><p role="status">おたよりを読み込み中…</p></main>;

  if (!intakeId) {
    return (
      <main className="app-shell">
        <div className="today-page-heading">
          <div><p className="eyebrow">園・Codmon画像</p><h1>おたより確認</h1></div>
        </div>
        <p className="empty-hint">LINEで送った画像のうち、おたよりらしいものだけがここに並びます。家族写真は解析対象から外します。</p>
        {error && <p role="alert" className="error-text">{error}</p>}
        {pending.length === 0 ? (
          <section className="card"><h2>確認待ちはありません</h2><p>新しいおたよりをLINEで送ると、解析候補がここに表示されます。</p></section>
        ) : (
          <ul className="task-list">
            {pending.map((row) => (
              <li key={row.intake_id} className="card">
                <div>
                  <strong>{row.status === 'needs_clarification' ? '確認が必要なおたより' : '登録内容を確認できます'}</strong>
                  <p className="task-item-meta">候補 {row.item_count}件 · {new Date(row.received_at).toLocaleString('ja-JP')}</p>
                  {row.ambiguity_fields.length > 0 && <p>確認: {row.ambiguity_fields.map((field) => AMBIGUITY_LABELS[field] ?? field).join('・')}</p>}
                </div>
                <Link className="secondary-button" to={`/nursery/reviews/${row.intake_id}`}>内容を見る</Link>
              </li>
            ))}
          </ul>
        )}
      </main>
    );
  }

  if (!review) {
    return <main className="app-shell"><p role="alert" className="error-text">{error ?? 'おたよりを表示できませんでした。'}</p><Link to="/nursery/reviews">一覧へ戻る</Link></main>;
  }

  if (done || review.status === 'confirmed') {
    return (
      <main className="app-shell">
        <section className="card success-card">
          <p className="eyebrow">登録完了</p>
          <h1>確認した内容を登録しました</h1>
          <p>選ばなかった候補は登録していません。予定・共有・ToDo・準備ルールは、人が選んだ内容だけ反映します。</p>
          <button type="button" className="hero-primary" onClick={() => navigate('/today')}>今日へ戻る</button>
        </section>
      </main>
    );
  }

  return (
    <main className="app-shell nursery-review-page">
      <div className="today-page-heading">
        <div><p className="eyebrow">園・Codmon画像 · 1画面確認</p><h1>この内容で登録しますか？</h1></div>
        <Link to="/nursery/reviews">一覧へ</Link>
      </div>

      {error && <p role="alert" className="error-text">{error}</p>}

      {review.raw_available && review.source_image_url ? (
        <section className="card">
          <div className="section-heading"><h2>元のおたより</h2><span>家庭内だけ</span></div>
          <img src={review.source_image_url} alt="確認中のおたより原画像" style={{ width: '100%', height: 'auto', borderRadius: 12 }} />
          <p className="empty-hint">この画像はLINEへ再送しません。構造化した確定内容を残したまま画像だけ削除できます。</p>
          <button type="button" className="text-button" disabled={busy} onClick={deleteSourceImage}>元画像だけ削除</button>
        </section>
      ) : (
        <section className="card compact-section"><p>元画像は削除済みです。確定済みの構造化データはそのまま残ります。</p></section>
      )}

      {(review.ambiguity_fields.length > 0 || !review.child_school_context_id) && (
        <section className="card decision-card">
          <p className="eyebrow">曖昧なところだけ確認</p>
          <h2>{review.ambiguity_fields.map((field) => AMBIGUITY_LABELS[field] ?? field).join('・') || '園・子ども・クラス'}</h2>
          <label>
            <span>対象</span>
            <select value={selectedContextId} onChange={(event) => setSelectedContextId(event.target.value)}>
              <option value="">選んでください</option>
              {review.available_contexts.map((context) => <option key={context.id} value={context.id}>{contextLabel(context)}</option>)}
            </select>
          </label>
          <p className="empty-hint">日付や「同じ資料か」は下の候補を確認・修正したうえで、このボタンで解消します。</p>
          <button type="button" className="hero-primary" disabled={busy || !selectedContextId} onClick={resolveAmbiguity}>この対象・内容で曖昧点を解消</button>
        </section>
      )}

      <section aria-label="登録候補">
        <div className="section-heading">
          <div><p className="eyebrow">登録前の候補</p><h2>{review.items.length}件</h2></div>
          <span>{selectedCount}件を登録</span>
        </div>
        {review.items.map((item) => (
          <ReviewItemEditor
            key={item.id}
            item={item}
            draft={drafts[item.id] ?? makeDraft(item)}
            onChange={(next) => setDrafts((current) => ({ ...current, [item.id]: next }))}
          />
        ))}
      </section>

      <section className="card sticky-confirm-card">
        <h2>確認して登録</h2>
        <p>{selectedCount}件を登録します。候補のままでは予定・共有・ToDo・準備ルールは変更されません。</p>
        <button
          type="button"
          className="hero-primary"
          disabled={busy || review.ambiguity_fields.length > 0 || !review.child_school_context_id || hasDraftJsonError}
          onClick={confirmReview}
        >
          {busy ? '処理中…' : `選んだ${selectedCount}件を登録`}
        </button>
      </section>
    </main>
  );
}