import { useState, type FormEvent } from 'react';
import { useAuth } from '../../app/AuthContext';
import { supabase } from '../../lib/supabaseClient';

export function PasswordReset() {
  const { user, loading } = useAuth();
  const [password, setPassword] = useState('');
  const [confirmation, setConfirmation] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  async function save(event: FormEvent) {
    event.preventDefault();
    if (password !== confirmation) {
      setError('2つのパスワードが一致していません。');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const { error } = await supabase.auth.updateUser({ password });
      if (error) throw error;
      setDone(true);
    } catch {
      setError('更新できませんでした。リンクの有効期限と通信状態を確認してください。');
    } finally {
      setBusy(false);
    }
  }
  return (
    <main className="app-shell centered">
      <h1>パスワードの再設定</h1>
      {loading ? (
        <p role="status">リンクを確認中…</p>
      ) : done ? (
        <>
          <p role="status">パスワードを更新しました。</p>
          <a href="/today">おうちノートを開く</a>
        </>
      ) : !user ? (
        <>
          <p role="alert">
            リンクの有効期限が切れている可能性があります。ログイン画面から再設定メールを送り直してください。
          </p>
          <a href="/">ログインへ</a>
        </>
      ) : (
        <form onSubmit={save}>
          <label>
            新しいパスワード
            <input
              type="password"
              autoComplete="new-password"
              minLength={6}
              required
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
          </label>
          <label>
            もう一度入力
            <input
              type="password"
              autoComplete="new-password"
              minLength={6}
              required
              value={confirmation}
              onChange={(e) => setConfirmation(e.target.value)}
            />
          </label>
          <button disabled={busy}>{busy ? '更新中…' : 'パスワードを更新'}</button>
        </form>
      )}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </main>
  );
}
