import { describe, expect, it } from 'vitest';
import type { TodayTaskInstance } from './useTodayData';
import { routineGroupTasks } from './routineGroupTasks';

describe('routine groups', () => {
  it('groups only today’s own required tasks following the transport role', () => {
    const task = (id: string, fields: Partial<TodayTaskInstance> = {}) => ({
      id, scheduled_date: '2026-11-21', routine_phase: 'evening',
      planned_assignee_id: 'p', assignee_strategy: 'pickup_assignee',
      status: 'todo', assignment_mode: 'person', ...fields,
    } as TodayTaskInstance);
    const tasks = [
      task('duty'), task('other', { planned_assignee_id: 'm' }),
      task('optional', { expectation: 'optional' }), task('unassigned', { assignment_mode: 'anyone' }),
      task('fixed', { assignee_strategy: 'fixed' }), task('other-day', { scheduled_date: '2026-11-22' }),
      task('done', { status: 'completed' }),
    ];
    expect(routineGroupTasks(tasks, 'evening', 'p', '2026-11-21').map((row) => row.id)).toEqual(['duty']);
    expect(routineGroupTasks(tasks, 'morning', 'p', '2026-11-21')).toEqual([]);
  });
});
