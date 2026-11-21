import type { TodayTaskInstance } from './useTodayData';

export function routineGroupTasks(tasks: TodayTaskInstance[], phase: 'morning' | 'evening', userId: string | undefined, today: string) {
  const strategy = phase === 'morning' ? 'dropoff_assignee' : 'pickup_assignee';
  return tasks.filter((task) =>
    Boolean(userId) && task.planned_assignee_id === userId &&
    task.scheduled_date === today && task.routine_phase === phase &&
    task.assignee_strategy === strategy && task.assignment_mode !== 'anyone' &&
    task.expectation !== 'optional' && ['todo', 'in_progress'].includes(task.status)
  );
}
