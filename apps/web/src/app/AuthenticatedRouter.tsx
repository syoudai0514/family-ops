import { BrowserRouter } from 'react-router-dom';
import { AuthGate } from './AuthGate';
import { AppErrorBoundary } from '../components/AppErrorBoundary';

export default function AuthenticatedRouter() {
  return (
    <BrowserRouter>
      <AppErrorBoundary>
        <AuthGate />
      </AppErrorBoundary>
    </BrowserRouter>
  );
}
