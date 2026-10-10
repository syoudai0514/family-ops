import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react';

// Long enough to notice a mistap, short enough not to keep covering the list (owner 2026-10-10).
const UNDO_VISIBLE_MS = 8000;

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
  useEffect(() => {
    if (!action || busy || error) return;
    const timer = window.setTimeout(() => {
      setAction((current) => (current === action ? null : current));
      if (latestAction.current === action) latestAction.current = null;
    }, UNDO_VISIBLE_MS);
    return () => window.clearTimeout(timer);
  }, [action, busy, error]);
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
