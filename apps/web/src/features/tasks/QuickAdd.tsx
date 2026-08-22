import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Modal } from '../../components/Modal';
import { TaskFormModal } from './TaskFormModal';

type QuickAddTarget = 'task' | 'request' | 'shopping' | 'handover' | 'routine' | 'preparation';

export function quickAddDestination(target: Exclude<QuickAddTarget, 'task'>) {
  if (target === 'request') return '/requests';
  if (target === 'shopping') return '/shopping';
  if (target === 'handover') return '/handovers';
  if (target === 'preparation') return '/settings/routines#morning-preparation';
  return '/settings/routines#custom-routines';
}

export function QuickAdd({ className, label = '＋', ariaLabel = '追加する', onTaskSaved }: {
  className?: string;
  label?: string;
  ariaLabel?: string;
  onTaskSaved?: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [taskFormOpen, setTaskFormOpen] = useState(false);
  const navigate = useNavigate();
  const choose = (target: QuickAddTarget) => {
    setOpen(false);
    if (target === 'task') setTaskFormOpen(true);
    else navigate(quickAddDestination(target));
  };
  return <>
    <button type="button" aria-label={ariaLabel} className={className} onClick={() => setOpen(true)}>{label}</button>
    {open && <Modal title="追加するもの" onClose={() => setOpen(false)}>
      <div className="quick-add-list">
        <button onClick={() => choose('task')}><b>単発予定を追加</b><small>歯医者・特別持ち物・行事</small></button>
        <button onClick={() => choose('request')}><b>お願いを送る</b><small>担当変更や依頼</small></button>
        <button onClick={() => choose('shopping')}><b>買い物を追加</b></button>
        <button onClick={() => choose('handover')}><b>引き継ぎを書く</b></button>
        <button onClick={() => choose('routine')}><b>定例を追加</b><small>送迎・朝夜家事の毎週ルール</small></button>
        <button onClick={() => choose('preparation')}><b>朝準備を編集</b></button>
      </div>
    </Modal>}
    {taskFormOpen && <TaskFormModal mode="create" onClose={() => setTaskFormOpen(false)} onSaved={() => {
      setTaskFormOpen(false);
      onTaskSaved?.();
      navigate('/today');
    }} />}
  </>;
}
