import { useCallback, useEffect, useRef, useState } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';

export type AssignmentReview = { definition_id: string; title: string; review_suggested: boolean; tentative: boolean };
export type AssignmentReviewState = { routines: AssignmentReview[]; transport_tentative: boolean };
type ReviewAction = 'keep' | 'stop' | 'optional';

export function AssignmentReviewPanel({ onLoaded, onChanged }: {
  onLoaded: (state: AssignmentReviewState | null) => void;
  onChanged: () => void;
}) {
  const [review, setReview] = useState<AssignmentReviewState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const sequence = useRef(0);
  const operations = useRef(new Map<string, string>());
  const load = useCallback(async () => {
    const current = ++sequence.current;
    try {
      const value = await callEdgeFunction<AssignmentReviewState>(EDGE_FUNCTIONS.assignmentConsentReview, { action: 'read' }, { policy: 'read' });
      if (current !== sequence.current) return;
      if (!value || !Array.isArray(value.routines) || typeof value.transport_tentative !== 'boolean') throw new Error('invalid review');
      setReview(value); onLoaded(value); setError(null);
    } catch {
      if (current !== sequence.current) return;
      setReview(null); onLoaded(null); setError('担当の確認状況を読み込めませんでした。');
    }
  }, [onLoaded]);
  useEffect(() => { void load(); return () => { ++sequence.current; }; }, [load]);

  const act = async (item: AssignmentReview, action: ReviewAction) => {
    const key = `${item.definition_id}:${action}`;
    const operationId = operations.current.get(key) ?? newOperationId();
    operations.current.set(key, operationId);
    setBusy(key); setError(null); setNotice(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.assignmentConsentReview, {
        action, task_definition_id: item.definition_id, operation_id: operationId,
      });
      operations.current.delete(key);
      setNotice(action === 'stop' ? 'この定例を止めました。' : action === 'optional' ? '余裕があればに変更しました。' : 'このままにしました。');
      await load(); onChanged();
    } catch (cause) {
      if (cause instanceof FamilyOpsApiError && cause.outcome === 'rejected') operations.current.delete(key);
      setError('変更を確認できませんでした。同じボタンでもう一度確認できます。');
    } finally { setBusy(null); }
  };

  const suggestions = review?.routines.filter((item) => item.review_suggested) ?? [];
  if (!suggestions.length && !error && !notice) return null;
  return (
    <section className="card" aria-labelledby="assignment-review-title">
      <h2 id="assignment-review-title">いつものことを見直す</h2>
      <p className="empty-hint">最近4週間、記録がない定例です。記録しないままでも大丈夫。必要に応じて、このまま続けるか選べます。</p>
      {error && <p role="alert">{error} <button type="button" className="text-button" onClick={() => void load()}>もう一度確認</button></p>}
      {notice && <p role="status">{notice}</p>}
      {suggestions.map((item) => (
        <article key={item.definition_id} className="routine-rule">
          <strong>{item.title}</strong>
          <div className="filter-chips">
            <button type="button" disabled={busy !== null} aria-label={`${item.title}をそのまま続ける`} onClick={() => void act(item, 'keep')}>そのまま</button>
            <button type="button" disabled={busy !== null} aria-label={`${item.title}を余裕があればにする`} onClick={() => void act(item, 'optional')}>余裕があれば</button>
            <button type="button" disabled={busy !== null} aria-label={`${item.title}をやめる`} onClick={() => void act(item, 'stop')}>やめる</button>
          </div>
        </article>
      ))}
    </section>
  );
}
