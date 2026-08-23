import { useEffect, useId, useRef } from 'react';
import type { ReactNode } from 'react';

export function Modal({
  title,
  onClose,
  children,
  headerAction,
  panelClassName,
  backdropClassName,
}: {
  title: string;
  onClose: () => void;
  children: ReactNode;
  headerAction?: ReactNode;
  panelClassName?: string;
  backdropClassName?: string;
}) {
  const panelRef = useRef<HTMLDivElement>(null);
  const modalId = useId();
  const restoredByBack = useRef(false);
  const onCloseRef = useRef(onClose);

  useEffect(() => {
    onCloseRef.current = onClose;
  }, [onClose]);

  useEffect(() => {
    const focused = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const originalOverflow = document.body.style.overflow;
    const originalTouchAction = document.body.style.touchAction;
    const previousHistoryState = window.history.state;
    document.body.style.overflow = 'hidden';
    document.body.style.touchAction = 'none';
    window.history.pushState({ ...previousHistoryState, familyOpsModal: modalId }, '');
    panelRef.current?.focus();

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onCloseRef.current();
    };
    const onPopState = () => {
      // Nested modals share the same popstate event. If the new history state
      // belongs to this modal, a child modal just closed and this one must stay.
      if (window.history.state?.familyOpsModal === modalId) return;
      restoredByBack.current = true;
      onCloseRef.current();
    };

    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('popstate', onPopState);
    return () => {
      document.body.style.overflow = originalOverflow;
      document.body.style.touchAction = originalTouchAction;
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('popstate', onPopState);
      // A successful save can unmount a modal without pressing its close
      // button. Restore the parent modal marker so Back/close still targets
      // the right layer instead of leaving a stale modal id behind.
      if (!restoredByBack.current && window.history.state?.familyOpsModal === modalId) {
        window.history.replaceState(previousHistoryState, '');
      }
      if (!restoredByBack.current && focused) focused.focus();
    };
  }, [modalId]);

  const requestClose = () => {
    if (window.history.state?.familyOpsModal === modalId) {
      window.history.back();
      return;
    }
    onClose();
  };

  return (
    <div
      className={['modal-backdrop', backdropClassName].filter(Boolean).join(' ')}
      onClick={requestClose}
    >
      <div
        className={['modal-panel', panelClassName].filter(Boolean).join(' ')}
        ref={panelRef}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="modal-header">
          <h2>{title}</h2>
          <div className="modal-header-actions">
            {headerAction}
            <button type="button" aria-label="閉じる" onClick={requestClose} className="modal-close">
              ×
            </button>
          </div>
        </div>
        {children}
      </div>
    </div>
  );
}
