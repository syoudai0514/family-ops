import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Modal } from '../../components/Modal';
import { TaskFormModal } from './TaskFormModal';

type QuickAddTarget = 'task' | 'request' | 'shopping' | 'handover' | 'routine' | 'preparation';

export const quickAddOptions: ReadonlyArray<{
  target: QuickAddTarget;
  label: string;
  detail?: string;
}> = [
  { target: 'task', label: '単発予定を追加', detail: '歯医者・特別持ち物・行事' },
  { target: 'request', label: 'お願いを送る', detail: '担当変更や依頼' },
  { target: 'shopping', label: '買い物を追加' },
  { target: 'handover', label: '引き継ぎを書く' },
  { target: 'routine', label: '定例を追加', detail: '送迎・朝夜家事の毎週ルール' },
  { target: 'preparation', label: '朝準備を編集' },
];

export function quickAddDestination(target: Exclude<QuickAddTarget, 'task'>) {
  if (target === 'request') return '/requests';
  if (target === 'shopping') return '/shopping';
  if (target === 'handover') return '/handovers';
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
  const isBottomNavAdd = className?.split(/\s+/).includes('bottom-nav-add') ?? false;
  const choose = (target: QuickAddTarget) => {
    setOpen(false);
    if (target === 'task') setTaskFormOpen(true);
    else navigate(quickAddDestination(target));
  };
  return (
    <>
      <button
        type="button"
        aria-label={ariaLabel}
        className={className}
        onClick={() => setOpen(true)}
      >
        {isBottomNavAdd ? (
          <svg
            aria-hidden="true"
            focusable="false"
            viewBox="0 0 24 24"
            width="24"
            height="24"
          >
            <path
              d="M12 5v14M5 12h14"
              fill="none"
              stroke="currentColor"
              strokeWidth="2.4"
              strokeLinecap="round"
            />
          </svg>
        ) : (
          label
        )}
      </button>
      {open && (
        <Modal title="追加するもの" onClose={() => setOpen(false)}>
          <div className="quick-add-list">
            {quickAddOptions.map((option) => (
              <button key={option.target} type="button" onClick={() => choose(option.target)}>
                <b>{option.label}</b>
                {option.detail && (
                  <small
                    style={{
                      color: 'var(--color-accent-text)',
                      opacity: 0.9,
                      fontWeight: 600,
                    }}
                  >
                    {option.detail}
                  </small>
                )}
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
