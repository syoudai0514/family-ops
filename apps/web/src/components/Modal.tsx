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
    const previousHistoryState = window.history.state;
    document.body.style.overflow = 'hidden';
    window.history.pushState({ ...previousHistoryState, familyOpsModal: modalId }, '');
    panelRef.current?.focus();

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onCloseRef.current();
    };
    const onPopState = () => {
      if (window.history.state?.familyOpsModal === modalId) return;
      restoredByBack.current = true;
      onCloseRef.current();
    };

    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('popstate', onPopState);
    return () => {
      document.body.style.overflow = originalOverflow;
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('popstate', onPopState);
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
