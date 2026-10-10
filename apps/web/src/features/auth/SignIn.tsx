import { type FormEvent, useState } from 'react';
import { supabase } from '../../lib/supabaseClient';
import { getAppEnv } from '../../lib/env';
import { rememberAuthReturnTo } from './authReturnTo';

export function SignIn({ onSignedIn }: { onSignedIn?: () => void } = {}) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState<'google' | 'password' | 'signup' | 'reset' | null>(null);

  function rememberCurrentLocation() {
    rememberAuthReturnTo(`${window.location.pathname}${window.location.search}${window.location.hash}`);
  }

  async function handleGoogleSignIn() {
    setError(null);
    setNotice(null);
    setSubmitting('google');
    try {
      // OAuth callbacks are always /auth/callback. Preserve a safe internal
      // deep link before leaving so first-time invitees return to /join.
      rememberCurrentLocation();
      const { supabaseUrl } = getAppEnv();
      const authorizeUrl = new URL(`${supabaseUrl}/auth/v1/authorize`);
      authorizeUrl.searchParams.set('provider', 'google');
      authorizeUrl.searchParams.set('redirect_to', `${window.location.origin}/auth/callback`);
      window.location.assign(authorizeUrl.toString());
    } catch (signInError) {
      setError(signInError instanceof Error ? signInError.message : 'サインインを開始できませんでした。');
      setSubmitting(null);
    }
  }

  async function handlePasswordSignIn(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setNotice(null);
    setSubmitting('password');
    rememberCurrentLocation();

    try {
      const { data, error: signInError } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
      if (signInError) { setError('メールアドレスとパスワードを確認してください。Googleで登録した場合はGoogleからログインしてください。'); return; }
      if (data.session) onSignedIn?.();
    } catch { setError('ログインを確認できませんでした。通信状態を確認して再試行してください。'); }
    finally { setSubmitting(null); }
  }

  async function handleSignUp() {
    setError(null);
    setNotice(null);
    setSubmitting('signup');
    rememberCurrentLocation();

    try {
      const { data, error: signUpError } = await supabase.auth.signUp({ email: email.trim(), password, options: { emailRedirectTo: `${window.location.origin}/auth/callback` } });
      if (signUpError) { setError(signUpError.message); return; }
      if (!data.session) { setNotice('確認メールを送信しました。メール内のリンクを開くと登録が完了します。'); return; }
      setNotice('登録しました。'); onSignedIn?.();
    } catch { setError('登録を確認できませんでした。通信状態を確認して再試行してください。'); }
    finally { setSubmitting(null); }
  }

  async function resetPassword() {
    if (!email.trim()) { setError('メールアドレスを入力してください。'); return; }
    setSubmitting('reset'); setError(null); setNotice(null);
    try {
      const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: `${window.location.origin}/auth/reset` });
      if (error) throw error;
      setNotice('再設定の案内をメールで送信しました。メール内のリンクを開いてください。');
    } catch { setError('メールを送信できませんでした。少し待ってから再試行してください。'); }
    finally { setSubmitting(null); }
  }
  const busy = submitting !== null;

  return (
    <main className="app-shell centered">
      <h1>おうちノート</h1>
      <p>家族の予定・家事・お願い・買い物・引き継ぎを、ひとつにまとめる共有ノート。</p>

      <form onSubmit={handlePasswordSignIn}>
        <label>
          メールアドレス
          <input
            type="email"
            name="email"
            autoComplete="email"
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            disabled={busy}
            required
          />
        </label>
        <label>
          パスワード
          <input
            type="password"
            name="password"
            autoComplete="current-password"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
            disabled={busy}
            minLength={6}
            required
          />
        </label>
        <div>
          <button type="submit" disabled={busy}>
            {submitting === 'password' ? 'ログイン中…' : 'メールでログイン'}
          </button>
          <button type="button" onClick={handleSignUp} disabled={busy || !email.trim() || password.length < 6}>
            {submitting === 'signup' ? '登録中…' : '新規登録'}
          </button>
        </div>
      </form>

      <button type="button" className="text-button" disabled={busy} onClick={() => void resetPassword()}>パスワードを忘れた場合</button>
      <p aria-hidden="true">または</p>

      <button type="button" onClick={handleGoogleSignIn} disabled={busy}>
        {submitting === 'google' ? 'サインイン中…' : 'Google でサインイン'}
      </button>

      {notice && <p role="status">{notice}</p>}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </main>
  );
}
