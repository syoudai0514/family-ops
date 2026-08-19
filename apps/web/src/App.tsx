import { BrowserRouter } from 'react-router-dom';
import './App.css';
import { AuthProvider } from './app/AuthContext';
import { AuthGate } from './app/AuthGate';

function App() {
  return (
    <BrowserRouter>
      <AuthProvider>
        <AuthGate />
      </AuthProvider>
    </BrowserRouter>
  );
}

export default App;
