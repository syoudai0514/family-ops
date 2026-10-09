import type { PlanningTask } from './calendarProjection';

/** Is there still an open dropoff / pickup / Codmon task on this day to take away? */
export function dayHasTransportToClear(tasks: PlanningTask[], date: string): boolean {
  return tasks.some((task) => {
    if (task.scheduled_date !== date) return false;
    if (task.status !== 'todo' && task.status !== 'in_progress') return false;
    if (task.origin !== 'recurring') return false;
    const code = task.definition_code ?? '';
    return code === 'dropoff' || code === 'pickup' || code.startsWith('codmon_') || task.task_kind === 'transport';
  });
}
