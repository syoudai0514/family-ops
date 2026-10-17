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
const googleTarget = vi.hoisted(() => ({ active: false }));
vi.mock('../planning/useFamilyCalendarWriteTarget', () => ({
  useFamilyCalendarWriteTarget: () => googleTarget.active,
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
    googleTarget.active = false;
    runCommand.mockResolvedValue({ task_id: 'task-created' });
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

  it('saves a cross-day event with long notes and its actual end date', async () => {
    render(<TaskFormModal mode="edit" task={task} onClose={vi.fn()} onSaved={vi.fn()} />);
    fireEvent.change(screen.getByLabelText('終了日'), { target: { value: '2026-10-06' } });
    fireEvent.change(screen.getByLabelText(/終了時刻/), { target: { value: '07:00' } });
    fireEvent.change(screen.getByLabelText('メモ'), { target: { value: '園からの長いお知らせ\n持ち物: 水筒' } });
    fireEvent.click(screen.getByRole('button', { name: '保存' }));
    await waitFor(() => expect(runCommand).toHaveBeenCalledOnce());
    expect(runCommand.mock.calls[0][2]('operation-1')).toMatchObject({
      expected_revision: 1, calendar_end_local_time: '07:00',
      scheduler_details: { ends_on: '2026-10-06', notes: '園からの長いお知らせ\n持ち物: 水筒' },
    });
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

  it('gives a new timed event the default reminder and allows several', async () => {
    const onSaved = vi.fn();
    render(<TaskFormModal mode="create" initialTitle="歯医者" initialScheduledDate="2026-10-20" initialCalendarVisibility="special" onClose={vi.fn()} onSaved={onSaved} />);
    fireEvent.change(screen.getByLabelText('開始時刻（任意）'), { target: { value: '14:00' } });
    expect(screen.getByRole('checkbox', { name: '1時間前' })).toBeChecked();
    fireEvent.click(screen.getByRole('checkbox', { name: '前日' }));
    fireEvent.click(screen.getByRole('button', { name: '保存' }));
    await waitFor(() => expect(onSaved).toHaveBeenCalledOnce());
    expect(runCommand.mock.calls[0][2]('operation-1').scheduler_details).toMatchObject({
      reminders: [60, 1440], reminder_minutes: null,
    });
  });

  it('defaults an all-day event to the evening before and can turn reminders off', async () => {
    const onSaved = vi.fn();
    render(<TaskFormModal mode="create" initialTitle="遠足" initialScheduledDate="2026-10-20" initialCalendarVisibility="special" onClose={vi.fn()} onSaved={onSaved} />);
    const evening = screen.getByRole('checkbox', { name: '前日 夜8時' });
    expect(evening).toBeChecked();
    fireEvent.click(evening);
    expect(screen.getByText(/通知しません。/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '保存' }));
    await waitFor(() => expect(onSaved).toHaveBeenCalledOnce());
    expect(runCommand.mock.calls[0][2]('operation-1').scheduler_details.reminders).toEqual([]);
  });

  it('shows a legacy single reminder as selected when editing', () => {
    render(<TaskFormModal mode="edit" task={{ ...task, scheduler_details: { reminder_minutes: 30 } } as never} onClose={vi.fn()} onSaved={vi.fn()} />);
    expect(screen.getByRole('checkbox', { name: '30分前' })).toBeChecked();
    expect(screen.getByRole('checkbox', { name: '1時間前' })).not.toBeChecked();
  });

  it('deletes from the edit form only after confirmation', async () => {
    const onSaved = vi.fn();
    const confirm = vi.spyOn(window, 'confirm').mockReturnValueOnce(false).mockReturnValueOnce(true);
    render(<TaskFormModal mode="edit" task={task} onClose={vi.fn()} onSaved={onSaved} />);
    fireEvent.click(screen.getByRole('button', { name: '削除' }));
    expect(runCommand).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: '削除' }));
    await waitFor(() => expect(onSaved).toHaveBeenCalledOnce());
    expect(runCommand.mock.calls[0][1]).toBe(EDGE_FUNCTIONS.cancelTask);
    expect(confirm).toHaveBeenCalledTimes(2);
  });

  it('leaves a timed event to Google Calendar when the family calendar is written there', async () => {
    googleTarget.active = true;
    const onSaved = vi.fn();
    render(<TaskFormModal mode="create" initialTitle="面談" initialScheduledDate="2026-10-20" initialCalendarVisibility="special" onClose={vi.fn()} onSaved={onSaved} />);
    fireEvent.change(screen.getByLabelText('開始時刻（任意）'), { target: { value: '14:00' } });
    fireEvent.change(screen.getByLabelText(/終了時刻/), { target: { value: '15:00' } });
    expect(screen.getByRole('radio', { name: 'Googleカレンダーの通知' })).toBeChecked();
    expect(screen.queryByRole('checkbox', { name: '1時間前' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '保存' }));
    await waitFor(() => expect(onSaved).toHaveBeenCalledOnce());
    expect(runCommand.mock.calls[0][2]('operation-1').scheduler_details.reminder_channel).toBe('google');
  });

  it('keeps start-only and all-day events on おうちノート even with Google connected', async () => {
    googleTarget.active = true;
    const onSaved = vi.fn();
    render(<TaskFormModal mode="create" initialTitle="準備" initialScheduledDate="2026-10-20" initialCalendarVisibility="special" onClose={vi.fn()} onSaved={onSaved} />);
    fireEvent.change(screen.getByLabelText('開始時刻（任意）'), { target: { value: '08:00' } });
    expect(screen.getByRole('radio', { name: 'Googleカレンダーの通知' })).toBeDisabled();
    expect(screen.getByRole('radio', { name: /おうちノートから通知/ })).toBeChecked();
    expect(screen.getByRole('checkbox', { name: '1時間前' })).toBeChecked();
    fireEvent.click(screen.getByRole('button', { name: '保存' }));
    await waitFor(() => expect(onSaved).toHaveBeenCalledOnce());
    expect(runCommand.mock.calls[0][2]('operation-1').scheduler_details).toMatchObject({ reminder_channel: 'app', reminders: [60] });
  });

  it('can choose おうちノート reminders for a Google-written timed event', async () => {
    googleTarget.active = true;
    const onSaved = vi.fn();
    render(<TaskFormModal mode="create" initialTitle="面談" initialScheduledDate="2026-10-20" initialCalendarVisibility="special" onClose={vi.fn()} onSaved={onSaved} />);
    fireEvent.change(screen.getByLabelText('開始時刻（任意）'), { target: { value: '14:00' } });
    fireEvent.change(screen.getByLabelText(/終了時刻/), { target: { value: '15:00' } });
    fireEvent.click(screen.getByRole('radio', { name: /おうちノートから通知/ }));
    fireEvent.click(screen.getByRole('checkbox', { name: '前日' }));
    fireEvent.click(screen.getByRole('button', { name: '保存' }));
    await waitFor(() => expect(onSaved).toHaveBeenCalledOnce());
    expect(runCommand.mock.calls[0][2]('operation-1').scheduler_details).toMatchObject({ reminder_channel: 'app', reminders: [60, 1440] });
  });

  it('creates a repeat without an end date by default', async () => {
    const onSaved = vi.fn();
    render(<TaskFormModal mode="create" initialTitle="スイミング" initialScheduledDate="2026-10-20" initialCalendarVisibility="special" onClose={vi.fn()} onSaved={onSaved} />);
    const repeat = screen.getByLabelText('繰り返し');
    expect(screen.getByRole('option', { name: '毎月第3火曜' })).toBeInTheDocument();
    fireEvent.change(repeat, { target: { value: 'biweekly' } });
    expect(screen.getByRole('checkbox', { name: /終わりの日を決める/ })).not.toBeChecked();
    fireEvent.click(screen.getByRole('button', { name: '保存' }));
    await waitFor(() => expect(onSaved).toHaveBeenCalledOnce());
    expect(runCommand.mock.calls[0][2]('operation-1').scheduler_details).toMatchObject({ repeat_frequency: 'biweekly', repeat_until: null });
  });

  it('edits a series occurrence for this date only unless これ以降すべて is chosen', async () => {
    const seriesTask = { ...task, scheduler_details: { series_id: 'series-1', repeat_frequency: 'weekly', repeat_until: null } } as never;
    const view = render(<TaskFormModal mode="edit" task={seriesTask} onClose={vi.fn()} onSaved={vi.fn()} />);
    expect(screen.getByLabelText('繰り返し')).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: '保存' }));
    await waitFor(() => expect(runCommand).toHaveBeenCalledOnce());
    expect(runCommand.mock.calls[0][2]('operation-1').edit_scope).toBe('this');
    view.unmount();
    runCommand.mockClear();
    render(<TaskFormModal mode="edit" task={seriesTask} onClose={vi.fn()} onSaved={vi.fn()} />);
    fireEvent.click(screen.getByRole('radio', { name: 'これ以降すべて' }));
    expect(screen.getByLabelText('繰り返し')).not.toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: '保存' }));
    await waitFor(() => expect(runCommand).toHaveBeenCalledOnce());
    expect(runCommand.mock.calls[0][2]('operation-1').edit_scope).toBe('following');
  });

  it('asks which occurrences to delete for a series', async () => {
    const onSaved = vi.fn();
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const seriesTask = { ...task, scheduler_details: { series_id: 'series-1', repeat_frequency: 'weekly', repeat_until: null } } as never;
    render(<TaskFormModal mode="edit" task={seriesTask} onClose={vi.fn()} onSaved={onSaved} />);
    fireEvent.click(screen.getByRole('button', { name: '削除' }));
    fireEvent.click(screen.getByRole('button', { name: 'これ以降をすべて削除' }));
    await waitFor(() => expect(onSaved).toHaveBeenCalledOnce());
    expect(runCommand.mock.calls[0][1]).toBe(EDGE_FUNCTIONS.cancelTask);
    expect(runCommand.mock.calls[0][2]('operation-1')).toMatchObject({ task_id: 'task-1', scope: 'following' });
  });
});
