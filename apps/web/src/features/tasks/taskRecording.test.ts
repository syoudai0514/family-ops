import { describe, expect, it } from 'vitest';
import { summarizeTaskRecording, taskRecordingLabel, type RecordingTask } from './taskRecording';

const date = '2026-10-06';
const task = (
  status: RecordingTask['status'],
  outcome_reason: RecordingTask['outcome_reason'] = null,
  scheduled_date = date,
): RecordingTask => ({ status, outcome_reason, scheduled_date });

describe('date-specific recording', () => {
  it('distinguishes all completed from all recorded with missed work', () => {
    expect(taskRecordingLabel(summarizeTaskRecording([task('completed')], date))).toBe(
      'すべて完了',
    );
    const summary = summarizeTaskRecording(
      [task('completed'), task('skipped', 'could_not_do')],
      date,
    );
    expect(summary).toMatchObject({
      total: 2,
      completed: 1,
      missed: 1,
      recorded: 2,
      pending: 0,
      state: 'recorded',
    });
    expect(taskRecordingLabel(summary)).toBe('記録済み・できなかった 1件');
  });
  it('only counts that day, excludes cancellations, and keeps partially checked or waiting work pending', () => {
    const summary = summarizeTaskRecording(
      [
        task('in_progress'),
        task('todo'),
        task('skipped', 'could_not_do'),
        task('cancelled'),
        task('completed', null, '2026-10-07'),
      ],
      date,
    );
    expect(summary).toMatchObject({ total: 3, missed: 1, pending: 2, state: 'pending' });
    expect(taskRecordingLabel(summary)).toBe('未記録 2件');
    expect(taskRecordingLabel(summary, true)).toBe('未完了 2件');
  });
  it('never describes an empty day or an explicitly unnecessary result as all completed', () => {
    expect(taskRecordingLabel(summarizeTaskRecording([task('cancelled')], date))).toBe(
      'やることなし',
    );
    expect(
      taskRecordingLabel(
        summarizeTaskRecording([task('skipped', 'not_needed_this_occurrence')], date),
      ),
    ).toBe('すべて記録済み');
  });
});

describe('summarizeTaskRecording for one person (owner 2026-10-09)', () => {
  const day = '2026-10-09';
  const row = (status: string, extra: Record<string, unknown> = {}) => ({ scheduled_date: day, status, outcome_reason: null, ...extra }) as never;

  it("is ○ when my own tasks are all done, even if the partner's are not", () => {
    const tasks = [
      row('completed', { planned_assignee_id: 'me' }),
      row('todo', { planned_assignee_id: 'partner' }),
      row('todo', { planned_assignee_id: 'partner' }),
    ];
    expect(summarizeTaskRecording(tasks, day).state).toBe('pending');
    expect(summarizeTaskRecording(tasks, day, { userId: 'me' })).toMatchObject({ state: 'completed', total: 1, pending: 0 });
    expect(summarizeTaskRecording(tasks, day, { userId: 'partner' })).toMatchObject({ state: 'pending', pending: 2 });
  });

  it('counts shared (誰でもOK) and unassigned tasks for both, until the other adult takes one', () => {
    const tasks = [
      row('todo', { assignment_mode: 'anyone' }),
      row('todo', { planned_assignee_id: null }),
      row('todo', { assignment_mode: 'anyone', active_claimant_user_id: 'partner' }),
    ];
    expect(summarizeTaskRecording(tasks, day, { userId: 'me' }).pending).toBe(2);
    expect(summarizeTaskRecording(tasks, day, { userId: 'partner' }).pending).toBe(3);
  });

  it('never counts an open optional task as left, but shows a recorded one', () => {
    const open = [row('completed', { planned_assignee_id: 'me' }), row('todo', { assignment_mode: 'anyone', expectation: 'optional' })];
    expect(summarizeTaskRecording(open, day, { userId: 'me' })).toMatchObject({ state: 'completed', total: 1 });
    const done = [row('completed', { planned_assignee_id: 'me' }), row('completed', { assignment_mode: 'anyone', expectation: 'optional' })];
    expect(summarizeTaskRecording(done, day, { userId: 'me' })).toMatchObject({ state: 'completed', total: 2 });
  });
});
