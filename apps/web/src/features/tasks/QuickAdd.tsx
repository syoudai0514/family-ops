import { useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { Modal } from '../../components/Modal';
import { TaskFormModal } from './TaskFormModal';

type QuickAddTarget = 'concierge' | 'task' | 'event' | 'request' | 'shopping' | 'handover' | 'routine' | 'preparation' | 'nursery' | 'actual';

export const quickAddOptions: ReadonlyArray<{
  target: QuickAddTarget;
  label: string;
  detail?: string;
}> = [
  { target: 'concierge', label: '✨ おうちコンシェルジュ', detail: '話しても、書いても。まとめて入力。' },
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

export function quickAddDestination(target: Exclude<QuickAddTarget, 'task'>) {
  if (target === 'concierge') return '/concierge';
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
  onTaskSaved,
}: {
  className?: string;
  label?: string;
  ariaLabel?: string;
  onTaskSaved?: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [taskFormOpen, setTaskFormOpen] = useState(false);
  const navigate = useNavigate();
  const location = useLocation();
  const isBottomNavAdd = className?.split(/\s+/).includes('bottom-nav-add') ?? false;
  const choose = (target: QuickAddTarget) => {
    setOpen(false);
    if (target === 'task') setTaskFormOpen(true);
    else navigate(quickAddDestination(target), { state: { originPath: location.pathname + location.search, originScrollY: window.scrollY } });
  };
  return (
    <>
      <button
        type="button"
        aria-label={ariaLabel}
        className={className}
        onClick={() => setOpen(true)}
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
      {open && (
        <Modal title="追加するもの" onClose={() => setOpen(false)}>
          <div className="quick-add-list">
            {quickAddOptions.map((option) => (
              <button key={option.target} type="button" onClick={() => choose(option.target)}>
                <b>{option.label}</b>
                {option.detail && <small>{option.detail}</small>}
              </button>
            ))}
          </div>
        </Modal>
      )}
      {taskFormOpen && (
        <TaskFormModal
          mode="create"
          onClose={() => setTaskFormOpen(false)}
          onSaved={() => {
            setTaskFormOpen(false);
            onTaskSaved?.();
            navigate('/today');
          }}
        />
      )}
    </>
  );
}
