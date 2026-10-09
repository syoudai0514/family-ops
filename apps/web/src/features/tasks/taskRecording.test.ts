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
    expect(taskRecordingLabel(summary)).toBe('記録済み・実施漏れ 1件');
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
