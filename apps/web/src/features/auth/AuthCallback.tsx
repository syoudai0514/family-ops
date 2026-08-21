import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../../app/AuthContext';
import { LoadingScreen } from '../../components/LoadingScreen';
import { consumeAuthReturnTo } from './authReturnTo';

// Landing point for the Google OAuth redirect. The Supabase client SDK
// detects the callback URL params on its own (detectSessionInUrl, on by
// default) and exchanges them for a session as part of AuthProvider's
// onAuthStateChange subscription — this component's only job is to show a
// spinner until that resolves, then hop into the app.
export function AuthCallback() {
  const { user, loading } = useAuth();
  const navigate = useNavigate();
  const [oauthError] = useState<string | null>(() =>
    new URLSearchParams(window.location.search).get('error_description'),
  );

  useEffect(() => {
    if (!loading && user) {
      navigate(consumeAuthReturnTo() ?? '/', { replace: true });
    }
  }, [loading, user, navigate]);

  if (oauthError) {
    return (
      <main className="app-shell centered">
        <p role="alert" className="error-text">
          サインインに失敗しました: {oauthError}
        </p>
      </main>
    );
  }

  if (!loading && !user) {
    return (
      <main className="app-shell centered">
        <p role="alert" className="error-text">
          サインインに失敗しました。もう一度お試しください。
        </p>
      </main>
    );
  }

  return <LoadingScreen label="サインイン処理中…" />;
}
