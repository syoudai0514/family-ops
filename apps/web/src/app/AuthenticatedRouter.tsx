import { BrowserRouter } from 'react-router-dom';
import { AuthProvider } from './AuthContext';
import { AuthGate } from './AuthGate';
import { AppErrorBoundary } from '../components/AppErrorBoundary';

export default function AuthenticatedRouter() {
  return (
    <BrowserRouter>
      <AppErrorBoundary>
        <AuthProvider>
          <AuthGate />
        </AuthProvider>
      </AppErrorBoundary>
    </BrowserRouter>
  );
}
