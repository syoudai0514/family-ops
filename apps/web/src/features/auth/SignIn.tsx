import { useState } from 'react';
import { supabase } from '../../lib/supabaseClient';

export function SignIn() {
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function handleSignIn() {
    setError(null);
    setSubmitting(true);
    const { error: signInError } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: {
        redirectTo: `${window.location.origin}/auth/callback`,
      },
    });
    if (signInError) {
      setError(signInError.message);
      setSubmitting(false);
    }
    // On success the browser navigates away to Google, so there is nothing
    // further to do here — no need to reset `submitting`.
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
