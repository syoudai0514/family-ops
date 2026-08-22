import { useState } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { useTaskCategories, type TaskCategoryOption } from '../tasks/useTaskCategories';

type EditableCategory = TaskCategoryOption & { isActive: boolean };

export function CategorySettings() {
  const { categories, refreshCategories } = useTaskCategories(true);
  const [draft, setDraft] = useState<EditableCategory[] | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const rows = draft ?? categories.map((category) => ({ ...category, isActive: category.isActive !== false }));
  const update = (index: number, patch: Partial<EditableCategory>) =>
    setDraft(rows.map((row, current) => current === index ? { ...row, ...patch } : row));
  const move = (from: number, offset: -1 | 1) => {
    const to = from + offset;
    if (to < 0 || to >= rows.length) return;
    const next = [...rows];
    [next[from], next[to]] = [next[to], next[from]];
    setDraft(next);
  };
  const save = async () => {
    setSaving(true); setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.updateTaskCategories, {
        operation_id: newOperationId(),
        categories: rows.map((row) => ({ code: row.code, label: row.label, accent_token: row.accentToken, is_active: row.isActive })),
      });
      setDraft(null); await refreshCategories();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : 'カテゴリを保存できませんでした。');
    } finally { setSaving(false); }
  };
  return <main className="app-shell settings-home">
    <h1>カテゴリ</h1>
    <p className="page-lead">予定追加で選ぶ項目です。担当色とは別に管理します。</p>
    <section className="card stack-form">
      {rows.map((row, index) => <div className="category-settings-row" key={row.code}>
        <input aria-label={`${row.code} の表示名`} value={row.label} onChange={(event) => update(index, { label: event.target.value })} />
        <select aria-label={`${row.code} の色`} value={row.accentToken ?? ''} onChange={(event) => update(index, { accentToken: event.target.value || null })}>
          <option value="">標準</option><option value="red">赤</option><option value="orange">橙</option><option value="purple">紫</option><option value="blue">青</option><option value="green">緑</option>
        </select>
        <label><input type="checkbox" checked={row.isActive} onChange={(event) => update(index, { isActive: event.target.checked })} />表示</label>
        <div className="category-order-actions" aria-label={`${row.label} の並び順`}>
          <button type="button" onClick={() => move(index, -1)} disabled={index === 0} aria-label="上へ">↑</button>
          <button type="button" onClick={() => move(index, 1)} disabled={index === rows.length - 1} aria-label="下へ">↓</button>
        </div>
      </div>)}
      <button type="button" onClick={() => setDraft([...rows, { code: `custom_${Date.now()}`, label: '新しいカテゴリ', accentToken: null, isActive: true }])}>＋ カテゴリを追加</button>
      {error && <p role="alert" className="error-text">{error}</p>}
      <button type="button" onClick={save} disabled={saving}>{saving ? '保存中…' : '保存'}</button>
    </section>
  </main>;
}
