import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { TaskInstance, TaskSubtaskInstance } from '../../lib/types';
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

function makeAnyoneTask(claimantUserId: string | null = null): TaskInstance {
  return {
    ...makeTask('todo'),
    id: 'anyone-1',
    title: '詩乃（便秘）の薬',
    origin: 'recurring',
    category: 'health',
    routine_phase: 'morning',
    assignment_mode: 'anyone',
    active_claimant_actor_ref_id: claimantUserId ? 'actor-ref-claimant' : null,
    active_claimant_user_id: claimantUserId,
    revision: 4,
  } as TaskInstance;
}

function makeSubtaskTask(): TaskInstance {
  return {
    ...makeTask('todo'),
    id: 'laundry-1',
    origin: 'recurring',
    title: '洗濯',
    category: 'housework',
    routine_phase: 'evening',
    completion_mode: 'subtasks',
  } as TaskInstance;
}

const laundrySubtasks: TaskSubtaskInstance[] = [
  { id: 'st-1', household_id: 'household-1', task_instance_id: 'laundry-1', title: '回す', required: true, sort_order: 1, is_completed: false, completed_by: null, completed_at: null },
  { id: 'st-2', household_id: 'household-1', task_instance_id: 'laundry-1', title: '干す/乾燥', required: true, sort_order: 2, is_completed: false, completed_by: null, completed_at: null },
  { id: 'st-3', household_id: 'household-1', task_instance_id: 'laundry-1', title: '畳む', required: true, sort_order: 3, is_completed: false, completed_by: null, completed_at: null },
];

const props = {
  subtasks: [],
  members: [],
  hasPartner: false,
  onEdit: vi.fn(),
  onChanged: vi.fn(),
};

describe('TaskChecklistItem Q54/Q64/Q106', () => {
  beforeEach(() => {
    sessionStorage.clear();
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

  it('shows fine-grained recurring subtasks immediately and records an individual checkbox', async () => {
    render(<TaskChecklistItem {...props} task={makeSubtaskTask()} subtasks={laundrySubtasks} />);

    expect(screen.getByText('洗濯')).toBeInTheDocument();
    expect(screen.getByText('回す')).toBeInTheDocument();
    expect(screen.getByText('干す/乾燥')).toBeInTheDocument();
    expect(screen.getByText('畳む')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('checkbox', { name: '回す' }));

    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('set-subtask-completion', {
      operation_id: '69000000-0000-4000-8000-000000000001',
      subtask_instance_id: 'st-1',
      completed: true,
      completion_actor: 'self',
    }));
  });

  it('restores the exact Today checklist detail expansion after leaving and returning', () => {
    const storageKey = 'today:task-expanded:laundry-1';
    const first = render(
      <TaskChecklistItem {...props} task={makeSubtaskTask()} subtasks={laundrySubtasks} expandedStorageKey={storageKey} />,
    );

    fireEvent.click(screen.getByRole('button', { name: '洗濯のチェック項目を閉じる' }));
    expect(sessionStorage.getItem(storageKey)).toBe('0');
    expect(screen.queryByText('回す')).not.toBeInTheDocument();
    first.unmount();

    const second = render(
      <TaskChecklistItem {...props} task={makeSubtaskTask()} subtasks={laundrySubtasks} expandedStorageKey={storageKey} />,
    );
    expect(screen.queryByText('回す')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '洗濯のチェック項目を開く' }));
    expect(sessionStorage.getItem(storageKey)).toBe('1');
    second.unmount();

    render(<TaskChecklistItem {...props} task={makeSubtaskTask()} subtasks={laundrySubtasks} expandedStorageKey={storageKey} />);
    expect(screen.getByText('回す')).toBeInTheDocument();
  });

  it('requires an explicit claim before executing a 誰でもOK task', async () => {
    const members = [
      { household_id: 'household-1', user_id: 'user-1', member_role: 'adult', family_role: 'papa', profile: null },
      { household_id: 'household-1', user_id: 'user-2', member_role: 'adult', family_role: 'mama', profile: null },
    ] as never[];

    render(
      <TaskChecklistItem
        {...props}
        members={members}
        currentUserId="user-1"
        task={makeAnyoneTask()}
      />,
    );

    expect(screen.getByText('誰でもOK')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '詩乃（便秘）の薬を完了にする' })).toBeDisabled();

    fireEvent.click(screen.getByRole('button', { name: '自分がやる' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('change-task-assignment', {
      operation_id: '69000000-0000-4000-8000-000000000001',
      task_id: 'anyone-1',
      claim_action: 'claim',
      expected_revision: 4,
    }));
  });

  it('shows the claimant and allows the claimant to release a 誰でもOK task', async () => {
    const members = [
      { household_id: 'household-1', user_id: 'user-1', member_role: 'adult', family_role: 'papa', profile: null },
    ] as never[];

    render(
      <TaskChecklistItem
        {...props}
        members={members}
        currentUserId="user-1"
        task={makeAnyoneTask('user-1')}
      />,
    );

    expect(screen.getByText('パパ対応中')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '詩乃（便秘）の薬を完了にする' })).not.toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: '手放す' }));

    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('change-task-assignment', {
      operation_id: '69000000-0000-4000-8000-000000000001',
      task_id: 'anyone-1',
      claim_action: 'release',
      expected_revision: 4,
    }));
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