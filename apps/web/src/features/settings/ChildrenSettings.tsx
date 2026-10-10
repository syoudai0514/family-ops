import { useState, type FormEvent } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { useFamilySetup, type FamilyChild, type SchoolContext } from './useFamilySetup';
import { useCommandAttempt } from '../../lib/useCommandAttempt';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { todayIsoDate } from '../../lib/date';

export function ChildrenSettings() {
  const { data, loading, error, refresh } = useFamilySetup();
  const run = useCommandAttempt();
  const location = useLocation();
  const returnTo = new URLSearchParams(location.search).get('returnTo');
  const safeReturn = returnTo?.startsWith('/nursery/reviews/') ? returnTo : '/settings';
  const empty = () => ({
    child_id: '',
    context_id: '',
    display_name: '',
    school_display_name: '',
    class_display_name: '',
    effective_from: todayIsoDate(),
    effective_to: '',
    recognition_aliases: '',
  });
  const [form, setForm] = useState(empty);
  const [editing, setEditing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  function edit(child: FamilyChild, context?: SchoolContext, newPeriod = false) {
    setForm({
      child_id: child.id,
      context_id: newPeriod ? '' : (context?.id ?? ''),
      display_name: child.display_name,
      school_display_name: context?.school_display_name ?? '',
      class_display_name: context?.class_display_name ?? '',
      effective_from: newPeriod ? todayIsoDate() : (context?.effective_from ?? todayIsoDate()),
      effective_to: newPeriod ? '' : (context?.effective_to ?? ''),
      recognition_aliases: context?.recognition_aliases.join('、') ?? '',
    });
    setEditing(true);
    setSaveError(null);
    setNotice(null);
  }
  async function save(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setSaveError(null);
    setNotice(null);
    const payload = {
      ...form,
      child_id: form.child_id || null,
      context_id: form.context_id || null,
      effective_to: form.effective_to || null,
      recognition_aliases: form.recognition_aliases
        .split(/[、,\n]/)
        .map((s) => s.trim())
        .filter(Boolean),
    };
    try {
      await run(
        `school-context:${JSON.stringify(payload)}`,
        EDGE_FUNCTIONS.familySetup,
        (operation_id) => ({ operation_id, action: 'save_context', payload }),
      );
      setEditing(false);
      setForm(empty());
      setNotice('子ども・園・クラスを保存しました。');
      await refresh();
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : '保存できませんでした。');
    } finally {
      setBusy(false);
    }
  }
  return (
    <main className="app-shell">
      <Link to={safeReturn}>‹ 戻る</Link>
      <h1>子ども・園・クラス</h1>
      <p>おたよりの対象を確認するための登録です。きょうだいごとに登録できます。</p>
      {loading && <p role="status">登録内容を確認中…</p>}
      {error && (
        <p role="alert">
          {error} <button onClick={() => void refresh()}>再読み込み</button>
        </p>
      )}
      {notice && <p role="status">{notice}</p>}
      {data?.children
        .filter((c) => c.active)
        .map((child) => (
          <section className="card" key={child.id}>
            <h2>{child.display_name}</h2>
            {data.contexts
              .filter((c) => c.child_id === child.id && c.active)
              .map((context) => (
                <article key={context.id}>
                  <strong>
                    {context.school_display_name} · {context.class_display_name || 'クラス未登録'}
                  </strong>
                  <p className="task-item-meta">
                    {context.effective_from} 〜 {context.effective_to || '終了日未定'}
                  </p>
                  <button className="text-button" onClick={() => edit(child, context)}>
                    内容・期間を編集
                  </button>
                  <button className="text-button" onClick={() => edit(child, context, true)}>
                    進級・転園の期間を追加
                  </button>
                </article>
              ))}
            {data.contexts.every((c) => c.child_id !== child.id) && (
              <button onClick={() => edit(child)}>園・クラスを登録</button>
            )}
          </section>
        ))}
      {!loading && data?.children.length === 0 && <p>まだ登録されていません。</p>}
      {!editing && (
        <button
          onClick={() => {
            setForm(empty());
            setEditing(true);
          }}
        >
          ＋子どもを登録
        </button>
      )}
      {editing && (
        <form className="card stack-form" onSubmit={save}>
          <h2>{form.context_id ? '登録内容を編集' : '対象を登録'}</h2>
          <label>
            子どもの名前
            <input
              required
              maxLength={120}
              value={form.display_name}
              disabled={busy}
              onChange={(e) => setForm({ ...form, display_name: e.target.value })}
            />
          </label>
          <label>
            園・学校名
            <input
              required
              maxLength={120}
              value={form.school_display_name}
              disabled={busy}
              onChange={(e) => setForm({ ...form, school_display_name: e.target.value })}
            />
          </label>
          <label>
            クラス（任意）
            <input
              maxLength={120}
              value={form.class_display_name}
              disabled={busy}
              onChange={(e) => setForm({ ...form, class_display_name: e.target.value })}
            />
          </label>
          <label>
            この園・クラスになる日
            <input
              type="date"
              required
              value={form.effective_from}
              disabled={busy}
              onChange={(e) => setForm({ ...form, effective_from: e.target.value })}
            />
          </label>
          <label>
            終了日（任意）
            <input
              type="date"
              min={form.effective_from}
              value={form.effective_to}
              disabled={busy}
              onChange={(e) => setForm({ ...form, effective_to: e.target.value })}
            />
          </label>
          <label>
            おたよりで使われる別名（任意）
            <input
              maxLength={2400}
              value={form.recognition_aliases}
              disabled={busy}
              placeholder="例：たんぽぽ組、たんぽぽ"
              onChange={(e) => setForm({ ...form, recognition_aliases: e.target.value })}
            />
          </label>
          <p className="task-item-meta">
            進級・転園では、前の期間の終了日を編集してから新しい期間を追加してください。過去のおたよりの対象は残ります。
          </p>
          {saveError && <p role="alert">{saveError}</p>}
          <div className="button-row">
            <button disabled={busy}>{busy ? '保存中…' : '保存する'}</button>
            <button
              type="button"
              className="text-button"
              disabled={busy}
              onClick={() => setEditing(false)}
            >
              やめる
            </button>
          </div>
        </form>
      )}
      {notice && returnTo && <Link to={safeReturn}>おたよりの確認に戻る</Link>}
    </main>
  );
}
