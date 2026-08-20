import { BrowserRouter } from 'react-router-dom';
import './App.css';
import { AuthProvider } from './app/AuthContext';
import { AuthGate } from './app/AuthGate';
import { AppErrorBoundary } from './components/AppErrorBoundary';

function App() {
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

export default App;
