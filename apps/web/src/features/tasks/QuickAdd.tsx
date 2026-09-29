import { useLocation, useNavigate } from 'react-router-dom';

export type QuickAddTarget = 'concierge' | 'task' | 'event' | 'request' | 'shopping' | 'handover' | 'routine' | 'preparation' | 'nursery' | 'actual';

export const quickAddOptions: ReadonlyArray<{
  target: Exclude<QuickAddTarget, 'concierge'>;
  label: string;
  detail?: string;
}> = [
  { target: 'task', label: '単発ToDoを追加', detail: 'タイトルだけでも作成可能' },
  { target: 'event', label: 'イベント・予定を追加', detail: '行事と準備ToDoをまとめて確認' },
  { target: 'request', label: 'お願いを送る', detail: '担当変更や依頼' },
  { target: 'shopping', label: '買い物を追加' },
  { target: 'handover', label: '引き継ぎを書く' },
  { target: 'nursery', label: '画像から取り込む' },
  { target: 'routine', label: '定例を追加' },
  { target: 'preparation', label: '朝準備を編集' },
  { target: 'actual', label: '予定外実績を追加' },
];

export const QUICK_ADD_PRIMARY_DESTINATION = '/concierge';

export function quickAddDestination(target: Exclude<QuickAddTarget, 'task'>) {
  if (target === 'concierge') return QUICK_ADD_PRIMARY_DESTINATION;
  if (target === 'actual') return '/actuals/new';
  if (target === 'event') return '/events/new';
  if (target === 'request') return '/requests';
  if (target === 'shopping') return '/shopping';
  if (target === 'handover') return '/handovers';
  if (target === 'nursery') return '/nursery/reviews';
  if (target === 'preparation') return '/settings/routines#morning-preparation';
  return '/settings/routines#custom-routines';
}

export function QuickAdd({
  className,
  label = '＋',
  ariaLabel = '追加する',
}: {
  className?: string;
  label?: string;
  ariaLabel?: string;
  onTaskSaved?: () => void;
}) {
  const navigate = useNavigate();
  const location = useLocation();
  const isBottomNavAdd = className?.split(/\s+/).includes('bottom-nav-add') ?? false;
  const openInput = () => navigate(QUICK_ADD_PRIMARY_DESTINATION, {
    state: {
      originPath: location.pathname + location.search,
      originScrollY: window.scrollY,
    },
  });

  return (
    <button
      type="button"
      aria-label={ariaLabel}
      className={className}
      onClick={openInput}
      style={
        isBottomNavAdd
          ? {
              position: 'relative',
              display: 'block',
              width: '44px',
              height: '44px',
              minWidth: '44px',
              minHeight: '44px',
              padding: 0,
              boxSizing: 'border-box',
              lineHeight: 0,
            }
          : undefined
      }
    >
      {isBottomNavAdd ? (
        <svg aria-hidden="true" focusable="false" viewBox="0 0 24 24" width="24" height="24" style={{ position: 'absolute', left: '50%', top: '50%', transform: 'translate(-50%, -50%)', display: 'block', margin: 0, pointerEvents: 'none' }}>
          <path d="M12 5v14M5 12h14" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" />
        </svg>
      ) : label}
    </button>
  );
}
