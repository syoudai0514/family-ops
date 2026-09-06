import { useEffect, useId, useRef } from 'react';
import type { ReactNode } from 'react';

type ScrollLockSnapshot = {
  scrollY: number;
  body: {
    overflow: string;
    position: string;
    top: string;
    left: string;
    right: string;
    width: string;
    overscrollBehavior: string;
  };
  root: {
    overflow: string;
    overscrollBehavior: string;
  };
};

let scrollLockDepth = 0;
let scrollLockSnapshot: ScrollLockSnapshot | null = null;

function lockPageScroll() {
  scrollLockDepth += 1;
  if (scrollLockDepth > 1) return;

  const body = document.body;
  const root = document.documentElement;
  const scrollY = window.scrollY;
  scrollLockSnapshot = {
    scrollY,
    body: {
      overflow: body.style.overflow,
      position: body.style.position,
      top: body.style.top,
      left: body.style.left,
      right: body.style.right,
      width: body.style.width,
      overscrollBehavior: body.style.overscrollBehavior,
    },
    root: {
      overflow: root.style.overflow,
      overscrollBehavior: root.style.overscrollBehavior,
    },
  };

  // `body { overflow:hidden }` alone still allows the document behind a
  // fixed modal to move in iOS Safari/PWA. Freeze the body at the current
  // visual position and lock the root as well. The modal panel itself keeps
  // its own vertical scrolling.
  root.style.overflow = 'hidden';
  root.style.overscrollBehavior = 'none';
  body.style.overflow = 'hidden';
  body.style.position = 'fixed';
  body.style.top = `-${scrollY}px`;
  body.style.left = '0';
  body.style.right = '0';
  body.style.width = '100%';
  body.style.overscrollBehavior = 'none';
}

function unlockPageScroll() {
  if (scrollLockDepth === 0) return;
  scrollLockDepth -= 1;
  if (scrollLockDepth > 0) return;

  const snapshot = scrollLockSnapshot;
  scrollLockSnapshot = null;
  if (!snapshot) return;

  const body = document.body;
  const root = document.documentElement;
  body.style.overflow = snapshot.body.overflow;
  body.style.position = snapshot.body.position;
  body.style.top = snapshot.body.top;
  body.style.left = snapshot.body.left;
  body.style.right = snapshot.body.right;
  body.style.width = snapshot.body.width;
  body.style.overscrollBehavior = snapshot.body.overscrollBehavior;
  root.style.overflow = snapshot.root.overflow;
  root.style.overscrollBehavior = snapshot.root.overscrollBehavior;
  window.scrollTo(0, snapshot.scrollY);
}

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
    const previousHistoryState = window.history.state;
    lockPageScroll();
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
      unlockPageScroll();
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
