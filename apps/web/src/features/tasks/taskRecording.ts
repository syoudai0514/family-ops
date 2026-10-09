import type { TaskInstance } from '../../lib/types';

export type RecordingTask = Pick<TaskInstance, 'scheduled_date' | 'status' | 'outcome_reason'> & {
  planned_assignee_id?: string | null;
  assignment_mode?: string | null;
  active_claimant_user_id?: string | null;
  /** 'optional': 余裕があれば. Never counts as left to record. */
  expectation?: string | null;
};
export type TaskRecordingSummary = ReturnType<typeof summarizeTaskRecording>;

export function isTaskRecorded(task: Pick<TaskInstance, 'status'>) {
  return task.status === 'completed' || task.status === 'skipped';
}

/**
 * Whose list a task is on. Mine: assigned to me, or shared (誰でもOK / nobody yet) and not taken
 * by the other adult. The other adult's own tasks are not mine to have recorded.
 */
export function isTaskOnUsersList(task: RecordingTask, userId: string) {
  if (task.assignment_mode === 'anyone') {
    return !task.active_claimant_user_id || task.active_claimant_user_id === userId;
  }
  return !task.planned_assignee_id || task.planned_assignee_id === userId;
}

/**
 * Scheduled date owns the result, even when it was recorded on a later day.
 * With `userId`, only that person's list counts (owner 2026-10-09: the day's ○ means "my tasks are
 * all done", not "the partner's are too"); without it, the whole household.
 * An optional task that is still open is never counted as left.
 */
export function summarizeTaskRecording(tasks: RecordingTask[], date: string, options: { userId?: string | null } = {}) {
  let total = 0;
  let completed = 0;
  let missed = 0;
  let recorded = 0;
  for (const task of tasks) {
    if (task.scheduled_date !== date || task.status === 'cancelled') continue;
    if (options.userId && !isTaskOnUsersList(task, options.userId)) continue;
    if (task.expectation === 'optional' && !isTaskRecorded(task)) continue;
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
