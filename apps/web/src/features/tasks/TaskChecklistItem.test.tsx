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
vi.mock('../../app/AuthContext', () => ({
  useAuth: () => ({ user: { id: 'user-1' } }),
}));
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ household: { id: 'household-1' } }),
}));

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
  it('also offers partner completion for anyone tasks', async () => {
    render(<TaskChecklistItem {...props} hasPartner currentUserId="user-1" task={makeAnyoneTask('user-2')} />);
    fireEvent.click(screen.getByRole('button', { name: '相手がやった' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('complete-task', expect.objectContaining({ task_id: 'anyone-1', completion_actor: 'partner' })));
  });
  it('records the partner directly, including the remaining checklist items', async () => {
    render(<TaskChecklistItem {...props} hasPartner task={makeSubtaskTask()} subtasks={laundrySubtasks} />);
    fireEvent.click(screen.getByRole('button', { name: '相手がやった' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('complete-task', expect.objectContaining({
      task_id: 'laundry-1', completion_actor: 'partner', complete_remaining_subtasks: true,
    })));
  });
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
      operation_id: expect.any(String),
      task_id: 'task-1',
      completion_actor: 'self',
      complete_remaining_subtasks: false,
    });
    expect(screen.queryByText('完了メモ（任意）')).not.toBeInTheDocument();
  });

  // Owner decision 2026-09-30: "コドモンで送信した" ends the Codmon job even with
  // inputs still unticked, through one server command (never a locked button).
  it('sends the Codmon acknowledgement command while inputs remain', async () => {
    render(
      <TaskChecklistItem
        {...props}
        task={{ ...makeTask('todo'), title: 'コドモン送信' } as TaskInstance}
        completionPrerequisite={{
          state: 'waiting_inputs',
          message: '9:15まで。',
          detailLabels: ['詩乃：朝食（パパ）'],
          blocking: false,
          actionLabel: 'コドモンで送信した',
          completeAction: 'codmon_submitted',
        }}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'コドモンで送信した' }));

    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(1));
    expect(callEdgeFunction).toHaveBeenCalledWith('complete-task', {
      operation_id: expect.any(String),
      task_id: 'task-1',
      action: 'codmon_submitted',
    });
  });

  it('finishes a whole checklist with one tap, without opening the individual boxes', async () => {
    render(<TaskChecklistItem {...props} task={makeSubtaskTask()} subtasks={laundrySubtasks} />);

    // Folded by default: nothing to tick one by one.
    expect(screen.queryByRole('checkbox', { name: '回す' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '洗濯を全部やったことにする' }));

    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('complete-task', {
      operation_id: expect.any(String),
      task_id: 'laundry-1',
      completion_actor: 'self',
      complete_remaining_subtasks: true,
    }));
  });

  it('keeps the individual boxes open once someone has started ticking them', () => {
    const partly = laundrySubtasks.map((item, index) => (index === 0 ? { ...item, is_completed: true } : item));
    render(<TaskChecklistItem {...props} hasPartner task={makeSubtaskTask()} subtasks={partly} />);
    expect(screen.getByRole('checkbox', { name: '干す/乾燥' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '洗濯を全部やったことにする' })).toBeInTheDocument();
    // "全部やった" and "相手がやった" sit side by side in one compact row under the title.
    const row = screen.getByRole('button', { name: '洗濯を全部やったことにする' }).closest('.task-actions');
    expect(row).not.toBeNull();
    expect(row!.contains(screen.getByRole('button', { name: '相手がやった' }))).toBe(true);
  });

  it('shows fine-grained recurring subtasks on request and records an individual checkbox', async () => {
    render(<TaskChecklistItem {...props} task={makeSubtaskTask()} subtasks={laundrySubtasks} />);

    expect(screen.getByText('洗濯')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '洗濯のチェック項目を開く' }));
    expect(screen.getByText('回す')).toBeInTheDocument();
    expect(screen.getByText('干す/乾燥')).toBeInTheDocument();
    expect(screen.getByText('畳む')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('checkbox', { name: '回す' }));

    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('set-subtask-completion', {
      operation_id: expect.any(String),
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

    expect(screen.queryByText('回す')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '洗濯のチェック項目を開く' }));
    expect(sessionStorage.getItem(storageKey)).toBe('1');
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

  it('lets an unclaimed 誰でもOK task record an actual directly while keeping claim optional', async () => {
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
    expect(screen.getByRole('button', { name: '詩乃（便秘）の薬を完了にする' })).not.toBeDisabled();
    // Optional and rarely used: in the ••• menu, not in the card's action row (owner 2026-10-04).
    expect(screen.getByRole('button', { name: '自分がやる' }).closest('details.task-overflow')).not.toBeNull();

    fireEvent.click(screen.getByRole('button', { name: '詩乃（便秘）の薬を完了にする' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('complete-task', {
      operation_id: expect.any(String),
      task_id: 'anyone-1',
      completion_actor: 'self',
      complete_remaining_subtasks: false,
    }));
  });

  it('lets an unclaimed 誰でもOK checklist record a subtask directly', async () => {
    const task = {
      ...makeSubtaskTask(),
      assignment_mode: 'anyone',
      active_claimant_actor_ref_id: null,
      active_claimant_user_id: null,
      revision: 5,
    } as TaskInstance;

    render(
      <TaskChecklistItem
        {...props}
        currentUserId="user-1"
        task={task}
        subtasks={laundrySubtasks}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: '洗濯のチェック項目を開く' }));
    const checkbox = screen.getByRole('checkbox', { name: '回す' });
    expect(checkbox).not.toBeDisabled();
    fireEvent.click(checkbox);

    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('set-subtask-completion', {
      operation_id: expect.any(String),
      subtask_instance_id: 'st-1',
      completed: true,
      completion_actor: 'self',
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
      operation_id: expect.any(String),
      task_id: 'anyone-1',
      claim_action: 'release',
      expected_revision: 4,
    }));
  });

  it('reopens an accidentally completed whole task from the completed surface', async () => {
    const completedTask = { ...makeTask('completed'), revision: 7 } as TaskInstance;
    render(<TaskChecklistItem {...props} task={completedTask} />);

    fireEvent.click(screen.getByRole('button', { name: '未完了に戻す' }));

    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('complete-task', {
      operation_id: expect.any(String),
      task_id: 'task-1',
      action: 'reopen',
      expected_revision: 7,
    }));
  });

  it('records a forgotten task as できなかった, apart from an open (未記録) one', async () => {
    render(<TaskChecklistItem {...props} task={makeAnyoneTask()} />);

    fireEvent.click(screen.getByRole('button', { name: 'できなかった（忘れた）' }));

    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('complete-task', {
      operation_id: expect.any(String),
      task_id: 'anyone-1',
      action: 'could_not_do',
    }));
  });

  it('shows できなかった as closed, with its own undo and no completion', async () => {
    const forgotten = { ...makeAnyoneTask(), status: 'skipped', outcome_reason: 'could_not_do' } as TaskInstance;
    render(<TaskChecklistItem {...props} hasPartner task={forgotten} />);

    expect(screen.getByRole('button', { name: '詩乃（便秘）の薬はできなかった' })).toBeDisabled();
    expect(screen.getByText(/できなかった$/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '相手がやった' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'できなかった（忘れた）' })).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '「できなかった」を取り消す' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('complete-task', {
      operation_id: expect.any(String),
      task_id: 'anyone-1',
      action: 'could_not_do_undo',
    }));
  });

  it('allows a completed checklist subtask to be unchecked and reopened', async () => {
    const completedTask = {
      ...makeSubtaskTask(),
      status: 'completed',
      completed_at: '2026-09-05T12:00:00+09:00',
      revision: 9,
    } as TaskInstance;
    const completedSubtasks = laundrySubtasks.map((item) => ({
      ...item,
      is_completed: true,
      completed_by: 'user-1',
      completed_at: '2026-09-05T12:00:00+09:00',
    }));

    render(<TaskChecklistItem {...props} task={completedTask} subtasks={completedSubtasks} />);
    fireEvent.click(screen.getByRole('button', { name: '修正する' }));

    const checkbox = screen.getByRole('checkbox', { name: '回す' });
    expect(checkbox).not.toBeDisabled();
    fireEvent.click(checkbox);

    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('set-subtask-completion', {
      operation_id: expect.any(String),
      subtask_instance_id: 'st-1',
      completed: false,
      completion_actor: 'self',
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
      operation_id: expect.any(String),
      task_id: 'task-1',
      note: '提出完了・受付済み',
      image: undefined,
    }));
    expect(await screen.findByText('証跡を追加しました。')).toBeInTheDocument();
  });
});
