import { describe, expect, it } from 'vitest';
import { groupRecurrencePatterns } from './routineRuleHelpers';

describe('groupRecurrencePatterns', () => {
  it('preserves per-weekday assignee and time differences including weekends', () => {
    const groups = groupRecurrencePatterns([
      {
        weekday: 1,
        assignee_strategy: 'fixed',
        planned_assignee_id: 'papa',
        scheduled_local_time: '20:00:00',
      },
      {
        weekday: 3,
        assignee_strategy: 'fixed',
        planned_assignee_id: 'mama',
        scheduled_local_time: '19:30:00',
      },
      {
        weekday: 6,
        assignee_strategy: 'fixed',
        planned_assignee_id: 'papa',
        scheduled_local_time: '20:00:00',
      },
      {
        weekday: 7,
        assignee_strategy: 'nonpickup_adult',
        planned_assignee_id: null,
        scheduled_local_time: '18:45:00',
      },
    ]);
    expect(groups.map((group) => group.map((rule) => rule.weekday))).toEqual([[1, 6], [3], [7]]);
    expect(groups.map((group) => group[0].scheduled_local_time)).toEqual([
      '20:00:00',
      '19:30:00',
      '18:45:00',
    ]);
  });
});
