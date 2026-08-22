import { useState } from 'react';
import { getAppEnv } from '../../lib/env';
import { rememberAuthReturnTo } from './authReturnTo';

export function SignIn() {
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function handleSignIn() {
    setError(null);
    setSubmitting(true);
    try {
      // OAuth callbacks are always /auth/callback. Preserve a safe internal
      // deep link before leaving so first-time invitees return to /join.
      rememberAuthReturnTo(`${window.location.pathname}${window.location.search}${window.location.hash}`);
      const { supabaseUrl } = getAppEnv();
      const authorizeUrl = new URL(`${supabaseUrl}/auth/v1/authorize`);
      authorizeUrl.searchParams.set('provider', 'google');
      authorizeUrl.searchParams.set('redirect_to', `${window.location.origin}/auth/callback`);
      window.location.assign(authorizeUrl.toString());
    } catch (signInError) {
      setError(signInError instanceof Error ? signInError.message : 'サインインを開始できませんでした。');
      setSubmitting(false);
    }
  }

  return (
    <main className="app-shell centered">
      <h1>Family Ops</h1>
      <p>家族の予定・家事・お願い・買い物・引き継ぎを共有する家庭運営OS。</p>
      <button type="button" onClick={handleSignIn} disabled={submitting}>
        {submitting ? 'サインイン中…' : 'Google でサインイン'}
      </button>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </main>
  );
}
