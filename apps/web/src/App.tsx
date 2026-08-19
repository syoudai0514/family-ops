import { useEffect, useState } from 'react';
import './App.css';
import { supabase } from './lib/supabaseClient';

type ConnectionState = 'checking' | 'ready' | 'error';

function App() {
  const [connectionState, setConnectionState] = useState<ConnectionState>('checking');

  useEffect(() => {
    let cancelled = false;
    supabase.auth
      .getSession()
      .then(() => {
        if (!cancelled) setConnectionState('ready');
      })
      .catch(() => {
        if (!cancelled) setConnectionState('error');
      });
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <main className="app-shell">
      <h1>Family Ops</h1>
      <p>家族の予定・家事・お願い・買い物・引き継ぎを共有する家庭運営OS。</p>
      <p data-testid="connection-state">Supabase connection: {connectionState}</p>
    </main>
  );
}

export default App;
