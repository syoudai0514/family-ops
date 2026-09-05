import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { TaskInstance } from '../../lib/types';
import { TaskChecklistItem } from './TaskChecklistItem';

const callEdgeFunction = vi.fn();
vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return { ...actual, callEdgeFunction: (...args: unknown[]) => callEdgeFunction(...args) };
});
vi.mock('../../lib/id', () => ({ newOperationId: () => '69000000-0000-4000-8000-000000000001' }));

function makeTask(status: 'todo' | 'completed'): TaskInstance {
  return {
    id: 'task-1', household_id: 'household-1', task_definition_id: null, recurrence_rule_id: null,
    origin: 'manual', title: '提出物を出す', category: 'nursery', routine_phase: 'anytime',
    scheduled_date: '2026-09-05', due_at: null, planned_assignee_id: null,
    completion_mode: 'whole', status,
    actual_completed_by_id: status === 'completed' ? 'user-1' : null,
    completed_at: status === 'completed' ? '2026-09-05T12:00:00+09:00' : null,
  } as TaskInstance;
}

const props = {
  subtasks: [],
  members: [],
  hasPartner: false,
  onEdit: vi.fn(),
  onChanged: vi.fn(),
};

describe('TaskChecklistItem Q106', () => {
  beforeEach(() => {
    callEdgeFunction.mockReset();
    callEdgeFunction.mockResolvedValue({ ok: true });
    props.onChanged.mockReset();
  });

  it('keeps ordinary whole-task completion as one direct tap with no evidence step', async () => {
    render(<TaskChecklistItem {...props} task={makeTask('todo')} />);

    fireEvent.click(screen.getByRole('button', { name: '提出物を出すを完了にする' }));

    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(1));
    expect(callEdgeFunction).toHaveBeenCalledWith('complete-task', {
      operation_id: '69000000-0000-4000-8000-000000000001',
      task_id: 'task-1',
      completion_actor: 'self',
      complete_remaining_subtasks: false,
    });
    expect(screen.queryByText('完了メモ（任意）')).not.toBeInTheDocument();
  });

  it('offers evidence only after completion and saves an optional memo separately', async () => {
    render(<TaskChecklistItem {...props} task={makeTask('completed')} />);

    expect(callEdgeFunction).not.toHaveBeenCalled();
    fireEvent.click(screen.getByText('証跡を追加（任意）'));
    expect(screen.getByText(/完了はすでに記録済みです/)).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('完了メモ（任意）'), { target: { value: '提出完了・受付済み' } });
    fireEvent.click(screen.getByRole('button', { name: '証跡を保存' }));

    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('add-task-completion-evidence', {
      operation_id: '69000000-0000-4000-8000-000000000001',
      task_id: 'task-1',
      note: '提出完了・受付済み',
      image: undefined,
    }));
    expect(await screen.findByText('証跡を追加しました。')).toBeInTheDocument();
  });
});
