import { describe, expect, it } from 'vitest';
import { buildCalendarProjection, transportLabel, type PlanningTask } from './calendarProjection';

const task = (overrides: Partial<PlanningTask>): PlanningTask => ({
  id: 'task', household_id: 'hh', task_definition_id: 'definition', recurrence_rule_id: null,
  origin: 'recurring', title: 'タスク', category: 'other', routine_phase: 'anytime',
  scheduled_date: '2026-08-24', due_at: null, planned_assignee_id: null,
  completion_mode: 'whole', status: 'todo', actual_completed_by_id: null, completed_at: null,
  ...overrides,
});

describe('CalendarProjection', () => {
  it('aggregates dropoff and pickup into one stable transport row', () => {
    const projection = buildCalendarProjection({
      primaryUserId: 'p', partnerUserId: 'm', occurrences: [],
      tasks: [
        task({ id: 'dropoff', category: 'dropoff', definition_code: 'dropoff', planned_assignee_id: 'p' }),
        task({ id: 'pickup', category: 'pickup', definition_code: 'pickup', planned_assignee_id: 'm' }),
      ],
    });
    expect(projection.allItems).toEqual([]);
    expect(transportLabel(projection.transportByDate.get('2026-08-24'), 'p', 'm')).toBe('送 P ｜ 迎 M');
  });

  it('excludes morning/evening routines without looking at task titles', () => {
    const projection = buildCalendarProjection({
      primaryUserId: 'p', partnerUserId: 'm', occurrences: [],
      tasks: [
        task({ id: 'bath', title: '完全に別名の定例', category: 'routine', routine_phase: 'evening' }),
        task({ id: 'special', title: 'エプロン持参', category: 'daycare_special', routine_phase: 'anytime', planned_assignee_id: 'p' }),
      ],
    });
    expect(projection.allItems.map((item) => item.id)).toEqual(['task:special']);
  });

  it('does not re-import a Family Ops generated Google mirror', () => {
    const projection = buildCalendarProjection({
      primaryUserId: 'p', partnerUserId: 'm', tasks: [],
      occurrences: [{
        id: 'occurrence', date: '2026-08-24', time: null, title: '送 P ｜ 迎 M', allDay: true,
        transparent: true, ownerUserId: null, providerEventId: 'provider-id', generatedByFamilyOps: true, hasConflict: false,
      }],
    });
    expect(projection.allItems).toEqual([]);
  });

  it('never dedupes an inbound event by a title, date, or local task id', () => {
    const projection = buildCalendarProjection({
      primaryUserId: 'p', partnerUserId: 'm',
      tasks: [task({ id: 'same-string', calendar_visibility: 'special' })],
      occurrences: [{
        id: 'external', date: '2026-08-24', time: null, title: '同じ表示名でも別予定', allDay: true,
        transparent: true, ownerUserId: null, providerEventId: 'same-string', generatedByFamilyOps: false, hasConflict: false,
      }],
    });
    expect(projection.allItems.map((item) => item.id)).toEqual(['task:same-string', 'google:external']);
  });

  it('shares exactly two Month content slots between special and Google events', () => {
    const projection = buildCalendarProjection({
      primaryUserId: 'p', partnerUserId: 'm',
      tasks: [task({ id: 'special', calendar_visibility: 'special', planned_assignee_id: 'p' })],
      occurrences: [
        { id: 'a', date: '2026-08-24', time: '2026-08-24T01:00:00Z', title: '歯医者', allDay: false, transparent: false, ownerUserId: 'm', providerEventId: null, generatedByFamilyOps: false, hasConflict: true },
        { id: 'b', date: '2026-08-24', time: null, title: '保護者会', allDay: true, transparent: true, ownerUserId: null, providerEventId: null, generatedByFamilyOps: false, hasConflict: false },
      ],
    });
    expect(projection.itemsByDate.get('2026-08-24')).toHaveLength(3);
    expect(projection.itemsByDate.get('2026-08-24')?.[0].id).toBe('google:a');
  });
});
