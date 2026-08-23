import { useEffect, useId, useRef } from 'react';
import type { ReactNode } from 'react';

export function Modal({
  title,
  onClose,
  children,
}: {
  title: string;
  onClose: () => void;
  children: ReactNode;
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
    document.body.style.overflow = 'hidden';
    document.body.style.touchAction = 'none';
    window.history.pushState({ ...window.history.state, familyOpsModal: modalId }, '');
    panelRef.current?.focus();
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onCloseRef.current();
    };
    const onPopState = () => {
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
    <div className="modal-backdrop" onClick={requestClose}>
      <div
        className="modal-panel"
        ref={panelRef}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="modal-header">
          <h2>{title}</h2>
          <button type="button" aria-label="閉じる" onClick={requestClose} className="modal-close">
            ×
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}
