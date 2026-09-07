import { useState } from 'react';
import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { TaskInstance } from '../../lib/types';
import { TaskFormModal } from './TaskFormModal';

vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ members: [] }),
}));
vi.mock('./useTaskCategories', () => ({
  useTaskCategories: () => ({ categories: [{ code: 'other', label: 'その他' }] }),
}));

const task = {
  id: 'task-1',
  title: '持ち物を確認',
  category: 'other',
  scheduled_date: '2026-09-07',
  due_at: null,
  calendar_ends_at: null,
  calendar_visibility: 'hidden',
  planned_assignee_id: null,
  completion_mode: 'whole',
  status: 'todo',
  origin: 'manual',
} as unknown as TaskInstance;

function OriginHarness() {
  const [open, setOpen] = useState(true);
  const [originFilter] = useState('今日・未完了');
  return <>
    <div data-testid="origin-state">元画面: {originFilter}</div>
    {open && <TaskFormModal mode="edit" task={task} onClose={() => setOpen(false)} onSaved={() => setOpen(false)} />}
  </>;
}

describe('task detail return state', () => {
  it('closes the edit overlay without replacing or resetting its origin screen', () => {
    render(<OriginHarness />);
    expect(screen.getByTestId('origin-state')).toHaveTextContent('元画面: 今日・未完了');
    expect(screen.getByRole('dialog')).toBeInTheDocument();

    fireEvent.click(screen.getByText('閉じる'));

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(screen.getByTestId('origin-state')).toHaveTextContent('元画面: 今日・未完了');
  });
});