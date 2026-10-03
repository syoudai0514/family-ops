import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { TaskFormModal } from './TaskFormModal';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import type { TaskInstance } from '../../lib/types';

const runCommand = vi.fn();

vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ members: [] }),
}));
vi.mock('../../lib/useCommandAttempt', () => ({
  useCommandAttempt: () => runCommand,
}));
vi.mock('./useTaskCategories', () => ({
  useTaskCategories: () => ({ categories: [{ code: 'other', label: 'その他' }] }),
}));

const task = {
  id: 'task-1',
  title: '食育の準備',
  category: 'other',
  scheduled_date: '2026-10-05',
  due_at: '2026-10-04T23:00:00Z',
  calendar_ends_at: null,
  calendar_visibility: 'special',
  planned_assignee_id: null,
  completion_mode: 'whole',
  status: 'todo',
  origin: 'manual',
} as unknown as TaskInstance;

describe('TaskFormModal special calendar time contract', () => {
  beforeEach(() => {
    sessionStorage.clear();
    vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
    runCommand.mockReset();
    runCommand.mockResolvedValue({});
  });

  it('creates a special task with a time and no invented end time', async () => {
    const onSaved = vi.fn();
    render(<TaskFormModal mode="create" initialTitle="食育の準備" initialScheduledDate="2026-10-05" initialCalendarVisibility="special" onClose={vi.fn()} onSaved={onSaved} />);
    fireEvent.change(screen.getByLabelText('開始時刻（任意）'), { target: { value: '08:00' } });
    fireEvent.click(screen.getByRole('button', { name: '保存' }));

    await waitFor(() => expect(onSaved).toHaveBeenCalledOnce());
    const [key, endpoint, buildPayload] = runCommand.mock.calls[0];
    expect(key).toBe('task-form:create');
    expect(endpoint).toBe(EDGE_FUNCTIONS.createTask);
    expect(buildPayload('operation-1')).toMatchObject({
      title: '食育の準備', scheduled_date: '2026-10-05', calendar_visibility: 'special', due_local_time: '08:00',
    });
    expect(buildPayload('operation-1').calendar_end_local_time).toBeUndefined();
  });

  it('allows an existing start-only special task to be edited', async () => {
    const onSaved = vi.fn();
    render(<TaskFormModal mode="edit" task={task} onClose={vi.fn()} onSaved={onSaved} />);
    fireEvent.change(screen.getByLabelText('何をする？'), { target: { value: '食育の準備を確認' } });
    fireEvent.click(screen.getByRole('button', { name: '保存' }));

    await waitFor(() => expect(onSaved).toHaveBeenCalledOnce());
    const [, endpoint, buildPayload] = runCommand.mock.calls[0];
    expect(endpoint).toBe(EDGE_FUNCTIONS.editTask);
    expect(buildPayload('operation-1')).toMatchObject({
      title: '食育の準備を確認', due_local_time: '08:00', calendar_end_local_time: null,
    });
  });

  it.each(['07:59', '08:00'])('still refuses an explicit end at or before the start (%s)', (endTime) => {
    render(<TaskFormModal mode="edit" task={task} onClose={vi.fn()} onSaved={vi.fn()} />);
    const end = screen.getByLabelText(/終了時刻/);
    fireEvent.change(end, { target: { value: endTime } });
    fireEvent.click(screen.getByRole('button', { name: '保存' }));

    expect(screen.getByRole('alert')).toHaveTextContent('終了時刻は開始時刻より後にしてください。');
    expect(runCommand).not.toHaveBeenCalled();
  });

  it('preserves an explicit valid end time for a timed event', async () => {
    const onSaved = vi.fn();
    render(<TaskFormModal mode="edit" task={task} onClose={vi.fn()} onSaved={onSaved} />);
    fireEvent.change(screen.getByLabelText(/終了時刻/), { target: { value: '09:00' } });
    fireEvent.click(screen.getByRole('button', { name: '保存' }));

    await waitFor(() => expect(onSaved).toHaveBeenCalledOnce());
    const [, , buildPayload] = runCommand.mock.calls[0];
    expect(buildPayload('operation-1')).toMatchObject({
      due_local_time: '08:00', calendar_end_local_time: '09:00',
    });
  });
});
