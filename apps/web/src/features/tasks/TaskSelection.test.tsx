import { UndoNoticeProvider } from '../../app/UndoNotice';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { TaskInstance, TaskSubtaskInstance } from '../../lib/types';
import { TaskChecklistItem } from './TaskChecklistItem';
import { TaskSelectionProvider, useTaskSelection } from './TaskSelection';

const callEdgeFunction = vi.fn();
vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return { ...actual, callEdgeFunction: (...args: unknown[]) => callEdgeFunction(...args) };
});
vi.mock('../../app/AuthContext', () => ({ useAuth: () => ({ user: { id: 'user-1' } }) }));
vi.mock('../../app/HouseholdContext', () => ({ useHousehold: () => ({ household: { id: 'household-1' } }) }));

function task(id: string, title: string, extra: Partial<TaskInstance> = {}): TaskInstance {
  return {
    id, household_id: 'household-1', task_definition_id: null, recurrence_rule_id: null, origin: 'recurring', title,
    category: 'housework', routine_phase: 'evening', scheduled_date: '2026-10-10', due_at: null,
    planned_assignee_id: 'user-1', completion_mode: 'whole', status: 'todo', actual_completed_by_id: null,
    completed_at: null, revision: 3, ...extra,
  } as TaskInstance;
}

function GroupButton() {
  const selection = useTaskSelection();
  return <button disabled={selection?.busy} onClick={() => void selection?.completeGroup(['t1', 't2'])}>当番を済みにする</button>;
}

function List({ tasks, onChanged, subtasks = {} }: { tasks: TaskInstance[]; onChanged: () => void; subtasks?: Record<string, TaskSubtaskInstance[]> }) {
  return (
    <UndoNoticeProvider>
      <TaskSelectionProvider onChanged={onChanged}>
        <GroupButton />
        <ul>
          {tasks.map((item) => (
            <TaskChecklistItem key={item.id} task={item} subtasks={subtasks[item.id] ?? []} members={[]} hasPartner={false}
              currentUserId="user-1" onEdit={vi.fn()} onChanged={onChanged} compact />
          ))}
        </ul>
      </TaskSelectionProvider>
    </UndoNoticeProvider>
  );
}

describe('ticking several tasks and recording them together', () => {
  beforeEach(() => {
    callEdgeFunction.mockReset();
    callEdgeFunction.mockResolvedValue({ ok: true, revision: 4 });
  });

  it('ticking only selects; nothing is saved until the bar is pressed', () => {
    render(<List tasks={[task('t1', 'お風呂'), task('t2', '洗濯')]} onChanged={vi.fn()} />);
    fireEvent.click(screen.getByRole('checkbox', { name: 'お風呂を選ぶ' }));
    fireEvent.click(screen.getByRole('checkbox', { name: '洗濯を選ぶ' }));
    expect(callEdgeFunction).not.toHaveBeenCalled();
    expect(screen.getByRole('status')).toHaveTextContent('2件を選択中');
  });

  it('completes every ticked task, refreshes once, and offers one undo for all', async () => {
    const onChanged = vi.fn();
    render(<List tasks={[task('t1', 'お風呂'), task('t2', '洗濯'), task('t3', '食洗機')]} onChanged={onChanged} />);
    fireEvent.click(screen.getByRole('checkbox', { name: 'お風呂を選ぶ' }));
    fireEvent.click(screen.getByRole('checkbox', { name: '洗濯を選ぶ' }));
    const bar = screen.getByRole('complementary', { name: '選んだ作業をまとめて記録' });
    fireEvent.click(bar.querySelector('button')!);

    expect(await screen.findByText('2件を完了にしました')).toBeInTheDocument();
    const completes = callEdgeFunction.mock.calls.filter((call) => call[0] === 'complete-task');
    expect(completes.map((call) => call[1].task_id)).toEqual(['t1', 't2']);
    expect(completes[0][1]).toEqual(expect.objectContaining({ completion_actor: 'self' }));
    expect(onChanged).toHaveBeenCalledTimes(1);

    callEdgeFunction.mockClear();
    fireEvent.click(screen.getByRole('button', { name: '元に戻す' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(2));
    expect(callEdgeFunction.mock.calls.map((call) => [call[1].task_id, call[1].action, call[1].expected_revision]))
      .toEqual([['t1', 'reopen', 4], ['t2', 'reopen', 4]]);
  });

  it('records a group in one tap and offers an undo for just those tasks', async () => {
    render(<List tasks={[task('t1', 'お風呂'), task('t2', '洗濯'), task('t3', '食洗機')]} onChanged={vi.fn()} />);
    fireEvent.click(screen.getByRole('button', { name: '当番を済みにする' }));
    expect(await screen.findByText('2件を完了にしました')).toBeInTheDocument();
    expect(callEdgeFunction.mock.calls.map((call) => call[1].task_id)).toEqual(['t1', 't2']);
    callEdgeFunction.mockClear();
    fireEvent.click(screen.getByRole('button', { name: '元に戻す' }));
    await waitFor(() => expect(callEdgeFunction.mock.calls.map((call) => call[1].task_id)).toEqual(['t1', 't2']));
  });

  it('explains that checklist work needs individual correction and only undoes eligible tasks', async () => {
    const check: TaskSubtaskInstance = { id: 's1', household_id: 'household-1', task_instance_id: 't2', title: '干す', required: true, sort_order: 1, is_completed: false, completed_by: null, completed_at: null };
    render(<List tasks={[task('t1', 'お風呂'), task('t2', '洗濯', { completion_mode: 'subtasks' })]} subtasks={{ t2: [check] }} onChanged={vi.fn()} />);
    fireEvent.click(screen.getByRole('button', { name: '当番を済みにする' }));
    expect(await screen.findByText('2件を完了にしました。1件は元に戻せます。残りは個別に確認してください。')).toBeInTheDocument();
    callEdgeFunction.mockClear();
    fireEvent.click(screen.getByRole('button', { name: '元に戻す' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(1));
    expect(callEdgeFunction.mock.calls[0][1]).toEqual(expect.objectContaining({ task_id: 't1', action: 'reopen' }));
  });

  it('does not offer the unsupported task-level undo for a single checklist', async () => {
    const check: TaskSubtaskInstance = { id: 's1', household_id: 'household-1', task_instance_id: 't2', title: '干す', required: true, sort_order: 1, is_completed: false, completed_by: null, completed_at: null };
    render(<UndoNoticeProvider><ul><TaskChecklistItem task={task('t2', '洗濯', { completion_mode: 'subtasks' })}
      subtasks={[check]} members={[]} hasPartner={false} currentUserId="user-1" onEdit={vi.fn()} onChanged={vi.fn()} compact /></ul></UndoNoticeProvider>);
    fireEvent.click(screen.getByRole('button', { name: '洗濯を完了にする' }));
    expect(await screen.findByText('洗濯を完了にしました。修正するときはチェック項目を確認してください。')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '元に戻す' })).not.toBeInTheDocument();
  });

  it('shows a result without an undo button when every completed task needs individual correction', async () => {
    const check: TaskSubtaskInstance = { id: 's1', household_id: 'household-1', task_instance_id: 't2', title: '干す', required: true, sort_order: 1, is_completed: false, completed_by: null, completed_at: null };
    render(<List tasks={[task('t2', '洗濯', { completion_mode: 'subtasks' })]} subtasks={{ t2: [check] }} onChanged={vi.fn()} />);
    fireEvent.click(screen.getByRole('checkbox', { name: '洗濯を選ぶ' }));
    fireEvent.click(screen.getByRole('button', { name: '✓ 完了' }));
    expect(await screen.findByText('1件を完了にしました。修正するときは個別に確認してください。')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '元に戻す' })).not.toBeInTheDocument();
  });

  it('continues undoing other tasks after a conflict and retries only the failed task', async () => {
    const onChanged = vi.fn();
    render(<List tasks={[task('t1', 'お風呂'), task('t2', '洗濯')]} onChanged={onChanged} />);
    fireEvent.click(screen.getByRole('button', { name: '当番を済みにする' }));
    await screen.findByText('2件を完了にしました');
    callEdgeFunction.mockClear();
    let firstFailure = true;
    callEdgeFunction.mockImplementation((_name, body: { task_id: string }) => {
      if (body.task_id === 't1' && firstFailure) { firstFailure = false; return Promise.reject(new Error('changed')); }
      return Promise.resolve({ ok: true, revision: 5 });
    });
    fireEvent.click(screen.getByRole('button', { name: '元に戻す' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('1件を元に戻せませんでした');
    expect(callEdgeFunction.mock.calls.map((call) => call[1].task_id)).toEqual(['t1', 't2']);
    callEdgeFunction.mockClear();
    fireEvent.click(screen.getByRole('button', { name: '元に戻す' }));
    await waitFor(() => expect(callEdgeFunction.mock.calls.map((call) => call[1].task_id)).toEqual(['t1']));
  });

  it('records ticked tasks as できなかった with the row revision', async () => {
    render(<List tasks={[task('t1', 'お風呂'), task('t2', '洗濯')]} onChanged={vi.fn()} />);
    fireEvent.click(screen.getByRole('checkbox', { name: '洗濯を選ぶ' }));
    fireEvent.click(screen.getByRole('button', { name: 'できなかった' }));
    expect(await screen.findByText('1件をできなかったにしました')).toBeInTheDocument();
    expect(callEdgeFunction).toHaveBeenCalledWith('complete-task', expect.objectContaining({ task_id: 't2', action: 'could_not_do', expected_revision: 3 }));
  });

  it('keeps a task another person is handling selected and says why it was not recorded', async () => {
    const claimed = task('t9', 'ゴミ出し', { assignment_mode: 'anyone', planned_assignee_id: null, active_claimant_actor_ref_id: 'ref-2', active_claimant_user_id: 'user-2' } as Partial<TaskInstance>);
    render(<List tasks={[claimed, task('t1', 'お風呂')]} onChanged={vi.fn()} />);
    fireEvent.click(screen.getByRole('checkbox', { name: 'ゴミ出しを選ぶ' }));
    fireEvent.click(screen.getByRole('checkbox', { name: 'お風呂を選ぶ' }));
    fireEvent.click(screen.getByRole('complementary', { name: '選んだ作業をまとめて記録' }).querySelector('button')!);
    expect(await screen.findByRole('alert')).toHaveTextContent('ゴミ出し（ほかの人が対応中です）');
    expect(callEdgeFunction.mock.calls.map((call) => call[1].task_id)).toEqual(['t1']);
    expect(screen.getByRole('checkbox', { name: 'ゴミ出しを選ぶ' })).toBeChecked();
  });

  it('shows the plain status icon, not a checkbox, outside a selection list and for recorded tasks', () => {
    render(<UndoNoticeProvider><ul>
      <TaskChecklistItem task={task('t1', 'お風呂')} subtasks={[]} members={[]} hasPartner={false} currentUserId="user-1" onEdit={vi.fn()} onChanged={vi.fn()} compact />
    </ul></UndoNoticeProvider>);
    expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
    render(<List tasks={[task('t2', '洗濯', { status: 'completed', actual_completed_by_id: 'user-1' })]} onChanged={vi.fn()} />);
    expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
  });
});
