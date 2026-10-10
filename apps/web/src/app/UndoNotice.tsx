import { createContext, useContext, useRef, useState, type ReactNode } from 'react';

type UndoAction = { label: string; undo: () => Promise<void> };
const UndoContext = createContext<(action: UndoAction) => void>(() => {});
export function useUndoNotice() {
  return useContext(UndoContext);
}
export function UndoNoticeProvider({ children }: { children: ReactNode }) {
  const [action, setAction] = useState<UndoAction | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const latestAction = useRef<UndoAction | null>(null);
  async function undo() {
    if (!action || busy) return;
    setBusy(true);
    setError(null);
    try {
      await action.undo();
      setAction((current) => (current === action ? null : current));
    } catch (err) {
      if (latestAction.current === action)
        setError(
          err instanceof Error
            ? err.message
            : '元に戻せませんでした。最新の記録を確認してください。',
        );
    } finally {
      setBusy(false);
    }
  }
  return (
    <UndoContext.Provider
      value={(next) => {
        latestAction.current = next;
        setAction(next);
        setError(null);
      }}
    >
      {children}
      {action && (
        <aside className="undo-notice" aria-label="操作の取り消し">
          <span role="status">{action.label}</span>
          <button type="button" disabled={busy} onClick={() => void undo()}>
            {busy ? '確認中…' : '元に戻す'}
          </button>
          <button
            type="button"
            className="text-button"
            disabled={busy}
            aria-label="取り消しの案内を閉じる"
            onClick={() => {
              latestAction.current = null;
              setAction(null);
              setError(null);
            }}
          >
            閉じる
          </button>
          {error && <p role="alert">{error}</p>}
        </aside>
      )}
    </UndoContext.Provider>
  );
}
