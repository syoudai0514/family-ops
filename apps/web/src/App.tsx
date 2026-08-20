import { lazy, Suspense } from 'react';
import { BrowserRouter, Route, Routes } from 'react-router-dom';
import './App.css';
import { SignIn } from './features/auth/SignIn';
import { LoadingScreen } from './components/LoadingScreen';
import { AppErrorBoundary } from './components/AppErrorBoundary';

// The complete authenticated app includes the Supabase database/realtime
// client and every household screen. Do not parse it before a session exists:
// iPhone Safari only needs the lightweight sign-in page on a first visit.
const AuthGate = lazy(() => import('./app/AuthGate').then((module) => ({ default: module.AuthGate })));

function hasStoredSession(): boolean {
  try {
    return Object.keys(window.localStorage).some((key) => key.startsWith('sb-') && key.endsWith('-auth-token'));
  } catch {
    return false;
  }
}

function App() {
  const sessionMayExist = hasStoredSession();

  return (
    <BrowserRouter>
      <AppErrorBoundary>
        <Routes>
          <Route
            path="/auth/callback"
            element={
              <Suspense fallback={<LoadingScreen label="サインイン処理中…" />}>
                <AuthGate />
              </Suspense>
            }
          />
          <Route
            path="*"
            element={
              sessionMayExist ? (
                <Suspense fallback={<LoadingScreen />}>
                  <AuthGate />
                </Suspense>
              ) : (
                <SignIn />
              )
            }
          />
        </Routes>
      </AppErrorBoundary>
    </BrowserRouter>
  );
}

export default App;
