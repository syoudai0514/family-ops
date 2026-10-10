import { useCallback, useEffect, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { useCommandAttempt } from '../../lib/useCommandAttempt';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';

type Subtask = { id?: string; title: string; required: boolean };
type Routine = { id: string; title: string; task_kind: string; subtasks: Subtask[] };
export function RoutineContentEditor() {
  const { household } = useHousehold();
  const householdId = household?.id;
  const run = useCommandAttempt();
  const [rows, setRows] = useState<Routine[]>([]);
  const [selected, setSelected] = useState('');
  const [draft, setDraft] = useState<Routine | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const load = useCallback(async () => {
    if (!householdId) {
      setRows([]);
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const [defs, subtasks] = await Promise.all([
        supabase
          .from('task_definitions')
          .select('id,title,task_kind')
          .eq('household_id', householdId)
          .eq('is_active', true)
          .in('task_kind', ['morning_chore', 'evening_chore'])
          .order('sort_order'),
        supabase
          .from('task_subtask_definitions')
          .select('id,task_definition_id,title,required')
          .eq('household_id', householdId)
          .eq('is_active', true)
          .order('sort_order'),
      ]);
      if (defs.error || subtasks.error) throw defs.error ?? subtasks.error;
      setRows(
        (defs.data ?? []).map((def) => ({
          ...def,
          subtasks: (subtasks.data ?? [])
            .filter((s) => s.task_definition_id === def.id)
            .map(({ id, title, required }) => ({ id, title, required })),
        })),
      );
    } catch {
      setError('定例の内容を取得できませんでした。');
    } finally {
      setLoading(false);
    }
  }, [householdId]);
  useEffect(() => {
    void load();
  }, [load]);
  async function save() {
    if (!draft) return;
    if (!draft.title.trim() || draft.subtasks.some((s) => !s.title.trim())) {
      setError('名前とチェック項目を入力してください。');
      return;
    }
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      // Each confirmed part is retry-safe; do not replay a response-lost save
      // with a new operation ID and duplicate newly added subtask definitions.
      await run(
        `routine-content:${draft.id}:items:${JSON.stringify(draft.subtasks)}`,
        EDGE_FUNCTIONS.replaceRoutineSubtasks,
        (operation_id) => ({
          operation_id,
          task_definition_id: draft.id,
          subtasks: draft.subtasks,
        }),
      );
      await run(
        `routine-content:${draft.id}:title:${draft.title}`,
        EDGE_FUNCTIONS.editTaskDefinition,
        (operation_id) => ({
          operation_id,
          task_definition_id: draft.id,
          title: draft.title.trim(),
        }),
      );
      setNotice(
        '保存しました。次に作られる定例から反映されます。今日や過去の記録はそのまま残ります。',
      );
      setDraft(null);
      setSelected('');
      await load();
    } catch (err) {
      setError(
        `${err instanceof Error ? err.message : '保存できませんでした。'} 一部だけ保存できた場合もあります。入力を保ったまま再確認してください。`,
      );
    } finally {
      setBusy(false);
    }
  }
  const updateSubtask = (index: number, patch: Partial<Subtask>) =>
    draft &&
    setDraft({
      ...draft,
      subtasks: draft.subtasks.map((s, i) => (i === index ? { ...s, ...patch } : s)),
    });
  return (
    <section className="card" id="routine-content">
      <h2>定例の名前・チェック項目</h2>
      <p className="empty-hint">
        朝・夜の定例を選んで内容を直せます。曜日と担当は下の設定で変更できます。
      </p>
      {loading ? (
        <p role="status">定例を確認中…</p>
      ) : (
        <label>
          直したい定例
          <select
            value={selected}
            disabled={busy}
            onChange={(e) => {
              setSelected(e.target.value);
              setDraft(rows.find((r) => r.id === e.target.value) ?? null);
              setNotice(null);
              setError(null);
            }}
          >
            <option value="">選んでください</option>
            {rows.map((r) => (
              <option value={r.id} key={r.id}>
                {r.task_kind === 'morning_chore' ? '朝' : '夜'} · {r.title}
              </option>
            ))}
          </select>
        </label>
      )}
      {draft && (
        <fieldset disabled={busy} className="stack-form">
          <legend>次回からの内容</legend>
          <label>
            定例の名前
            <input
              value={draft.title}
              maxLength={240}
              onChange={(e) => setDraft({ ...draft, title: e.target.value })}
            />
          </label>
          {draft.subtasks.map((s, i) => (
            <div key={s.id ?? `new-${i}`} className="subtask-row">
              <label>
                チェック項目 {i + 1}
                <input
                  value={s.title}
                  maxLength={240}
                  onChange={(e) => updateSubtask(i, { title: e.target.value })}
                />
              </label>
              <label>
                <input
                  type="checkbox"
                  checked={s.required}
                  onChange={(e) => updateSubtask(i, { required: e.target.checked })}
                />
                必須
              </label>
              <button
                type="button"
                className="text-button"
                onClick={() =>
                  setDraft({ ...draft, subtasks: draft.subtasks.filter((_, index) => index !== i) })
                }
              >
                外す
              </button>
            </div>
          ))}
          <button
            type="button"
            className="secondary-button"
            onClick={() =>
              setDraft({ ...draft, subtasks: [...draft.subtasks, { title: '', required: true }] })
            }
          >
            ＋チェック項目
          </button>
          <p className="task-item-meta">
            保存しても、設定済みの曜日・担当や個別の合意は変更しません。
          </p>
          <button type="button" onClick={() => void save()}>
            次回からの内容を保存
          </button>
        </fieldset>
      )}
      {error && (
        <p role="alert">
          {error}
          <button type="button" className="text-button" disabled={busy} onClick={() => void load()}>
            登録内容を再確認
          </button>
        </p>
      )}
      {notice && <p role="status">{notice}</p>}
    </section>
  );
}
