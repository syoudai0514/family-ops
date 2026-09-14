import { useEffect, useState } from 'react';
import { refreshCurrentPwa } from '../app/pwaFreshness';

export function LoadingScreen({
  label = '読み込み中…',
  recoveryAfterMs = 8_000,
  onReload = () => { void refreshCurrentPwa(); },
}: {
  label?: string;
  recoveryAfterMs?: number;
  onReload?: () => void;
}) {
  const [showRecovery, setShowRecovery] = useState(false);

  useEffect(() => {
    const timer = window.setTimeout(() => setShowRecovery(true), recoveryAfterMs);
    return () => window.clearTimeout(timer);
  }, [recoveryAfterMs]);

  return (
    <main className="app-shell centered">
      <p role="status">{label}</p>
      {showRecovery && (
        <div className="loading-recovery" role="alert">
          <p>読み込みが長引いています。通信が戻らない場合は、ここから安全に再読み込みできます。</p>
          <button type="button" onClick={onReload}>
            再読み込み
          </button>
        </div>
      )}
    </main>
  );
}
