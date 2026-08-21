import { lazy, Suspense } from 'react';
import './App.css';
import { SignIn } from './features/auth/SignIn';
import { LoadingScreen } from './components/LoadingScreen';

// A first visit only needs this sign-in screen. Keep React Router, Supabase,
// realtime, and every household feature in a separate chunk until a session
// exists or an OAuth callback is being handled.
const AuthenticatedRouter = lazy(() => import('./app/AuthenticatedRouter'));

function hasStoredSession(): boolean {
  try {
    return Object.keys(window.localStorage).some((key) => key.startsWith('sb-') && key.endsWith('-auth-token'));
  } catch {
    return false;
  }
}

function App() {
  const sessionMayExist = hasStoredSession();
  const needsAuthenticatedRouter = sessionMayExist || window.location.pathname === '/auth/callback';

  if (!needsAuthenticatedRouter) return <SignIn />;

  return (
    <Suspense fallback={<LoadingScreen label="サインイン処理中…" />}>
      <AuthenticatedRouter />
    </Suspense>
  );
}

export default App;
