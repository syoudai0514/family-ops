import { lazy, Suspense } from 'react';
import { Route, Routes } from 'react-router-dom';
import { useAuth } from './AuthContext';
import { SignIn } from '../features/auth/SignIn';
import { AuthCallback } from '../features/auth/AuthCallback';
import { LoadingScreen } from '../components/LoadingScreen';

const AuthenticatedApp = lazy(() => import('./AuthenticatedApp'));

// Top-level auth gate: unauthenticated visitors only ever see /auth/callback
// (needed mid-OAuth-flow) or the sign-in screen, regardless of what path
// they navigated to. Once authenticated, household-level gating takes over.
export function AuthGate() {
  const { user, loading } = useAuth();

  if (loading) {
    return (
      <Routes>
        <Route path="/auth/callback" element={<AuthCallback />} />
        <Route path="*" element={<LoadingScreen />} />
      </Routes>
    );
  }

  if (!user) {
    return (
      <Routes>
        <Route path="/auth/callback" element={<AuthCallback />} />
        <Route path="*" element={<SignIn />} />
      </Routes>
    );
  }

  return (
    <Suspense fallback={<LoadingScreen />}>
      <AuthenticatedApp />
    </Suspense>
  );
}
