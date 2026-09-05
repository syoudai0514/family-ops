import { useCallback, useEffect, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { supabase } from '../../lib/supabaseClient';

type Term = { id?: string; phrase: string; meaning: string };
export function HouseholdTerminology() {
  const { household } = useHousehold(); const [terms, setTerms] = useState<Term[]>([]);
  const [saving, setSaving] = useState(false); const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => {
    if (!household) return;
    const { data, error: readError } = await supabase.from('household_terminology').select('id, phrase, meaning').eq('household_id', household.id).order('created_at');
    if (readError) { setError('家庭内用語を読み込めませんでした。'); return; }
    setTerms((data ?? []).map((term) => ({ id: term.id, phrase: term.phrase, meaning: term.meaning })));
  }, [household]);
  useEffect(() => { void load(); }, [load]);
  const change = (index: number, patch: Partial<Term>) => setTerms((rows) => rows.map((row, current) => current === index ? { ...row, ...patch } : row));
  const save = async () => { setSaving(true); setError(null); try {
    await callEdgeFunction(EDGE_FUNCTIONS.updateHouseholdTerminology, { operation_id: newOperationId(), terms }); await load();
  } catch (err) { setError(err instanceof FamilyOpsApiError ? err.message : '家庭内用語を保存できませんでした。'); } finally { setSaving(false); } };
  return <main className="app-shell settings-home"><h1>家庭内用語</h1><p className="page-lead">ここで保存した言葉だけを、LINEの入力理解に使います。担当・曜日ルールは変わりません。</p>
    <section className="card stack-form" aria-label="確認済みの家庭内用語">{terms.map((term, index) => <div className="category-settings-row" key={term.id ?? `new-${index}`}>
      <input aria-label={`用語 ${index + 1}`} value={term.phrase} placeholder="例：送り" onChange={(event) => change(index, { phrase: event.target.value })} />
      <input aria-label={`意味 ${index + 1}`} value={term.meaning} placeholder="例：保育園の送り" onChange={(event) => change(index, { meaning: event.target.value })} />
      <button type="button" className="secondary-button" onClick={() => setTerms((rows) => rows.filter((_, current) => current !== index))}>削除</button>
    </div>)}<button type="button" onClick={() => setTerms((rows) => [...rows, { phrase: '', meaning: '' }])}>＋ 用語を追加</button>
    <p className="empty-hint">保存は「この意味で使う」の確認です。曖昧な推測だけでは登録されません。</p>{error && <p role="alert" className="error-text">{error}</p>}
    <button type="button" onClick={save} disabled={saving}>{saving ? '保存中…' : '確認して保存'}</button></section></main>;
}
