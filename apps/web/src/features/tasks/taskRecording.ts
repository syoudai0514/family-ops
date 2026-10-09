import type { TaskInstance } from '../../lib/types';

export type RecordingTask = Pick<TaskInstance, 'scheduled_date' | 'status' | 'outcome_reason'>;
export type TaskRecordingSummary = ReturnType<typeof summarizeTaskRecording>;

export function isTaskRecorded(task: Pick<TaskInstance, 'status'>) {
  return task.status === 'completed' || task.status === 'skipped';
}

/** Scheduled date owns the result, even when it was recorded on a later day. */
export function summarizeTaskRecording(tasks: RecordingTask[], date: string) {
  let total = 0;
  let completed = 0;
  let missed = 0;
  let recorded = 0;
  for (const task of tasks) {
    if (task.scheduled_date !== date || task.status === 'cancelled') continue;
    total++;
    if (task.status === 'completed') completed++;
    if (task.status === 'skipped' && task.outcome_reason === 'could_not_do') missed++;
    if (isTaskRecorded(task)) recorded++;
  }
  const pending = total - recorded;
  const state =
    total === 0
      ? 'empty'
      : pending > 0
        ? 'pending'
        : completed === total
          ? 'completed'
          : 'recorded';
  return { total, completed, missed, recorded, pending, state } as const;
}

export function taskRecordingLabel(summary: TaskRecordingSummary, future = false) {
  if (summary.state === 'empty') return 'やることなし';
  if (summary.pending > 0) return `${future ? '未完了' : '未記録'} ${summary.pending}件`;
  if (summary.state === 'completed') return 'すべて完了';
  return summary.missed > 0 ? `記録済み・実施漏れ ${summary.missed}件` : 'すべて記録済み';
}
