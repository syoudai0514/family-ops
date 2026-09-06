import { describe, expect, it } from 'vitest';
import { buildCalendarProjection, transportCompactToken, transportLabel, transportTokens, type PlanningTask } from './calendarProjection';

const task = (overrides: Partial<PlanningTask>): PlanningTask => ({
  id: 'task', household_id: 'hh', task_definition_id: 'definition', recurrence_rule_id: null,
  origin: 'recurring', title: 'タスク', category: 'other', routine_phase: 'anytime',
  scheduled_date: '2026-08-24', due_at: null, planned_assignee_id: null,
  completion_mode: 'whole', status: 'todo', actual_completed_by_id: null, completed_at: null,
  ...overrides,
});

describe('CalendarProjection', () => {
  it('aggregates dropoff and pickup and renders the exact compact transport contract', () => {
    const projection = buildCalendarProjection({
      primaryUserId: 'p', partnerUserId: 'm', occurrences: [],
      tasks: [
        task({ id: 'dropoff', category: 'dropoff', definition_code: 'dropoff', planned_assignee_id: 'p' }),
        task({ id: 'pickup', category: 'pickup', definition_code: 'pickup', planned_assignee_id: 'm' }),
      ],
    });
    const transport = projection.transportByDate.get('2026-08-24');
    expect(projection.allItems).toEqual([]);
    expect(transportCompactToken(transport, 'p', 'm')).toBe('送P迎M');
    expect(transportCompactToken(transport, 'p', 'm')).not.toMatch(/[\s|｜/]/);
    expect(transportLabel(transport, 'p', 'm')).toBe('送り：パパ / 迎え：ママ');
  });

  it('excludes morning/evening routines without looking at task titles', () => {
    const projection = buildCalendarProjection({
      primaryUserId: 'p', partnerUserId: 'm', occurrences: [],
      tasks: [
        task({ id: 'bath', title: '完全に別名の定例', category: 'routine', routine_phase: 'evening' }),
        task({ id: 'special', title: 'エプロン持参', category: 'daycare_special', routine_phase: 'anytime', calendar_visibility: 'special', planned_assignee_id: 'p' }),
      ],
    });
    expect(projection.allItems.map((item) => item.id)).toEqual(['task:special']);
  });

  it('does not re-import a Family Ops generated Google mirror', () => {
    const projection = buildCalendarProjection({
      primaryUserId: 'p', partnerUserId: 'm', tasks: [],
      occurrences: [{
        id: 'occurrence', date: '2026-08-24', time: null, title: '送P迎M', allDay: true,
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

  it('renders one-sided compact transport without placeholder or separator', () => {
    const dropoffProjection = buildCalendarProjection({ primaryUserId: 'p', partnerUserId: 'm', occurrences: [], tasks: [
      task({ id: 'dropoff', category: 'dropoff', definition_code: 'dropoff', planned_assignee_id: 'p' }),
    ] });
    const dropoff = dropoffProjection.transportByDate.get('2026-08-24');
    expect(transportCompactToken(dropoff, 'p', 'm')).toBe('送P');
    expect(transportLabel(dropoff, 'p', 'm')).toBe('送り：パパ / 迎え：未定');
    expect(transportTokens(dropoff, 'p', 'm')).toEqual({
      dropoff: { token: 'P', tone: 'primary' }, pickup: { token: '—', tone: 'none' },
    });

    const pickupProjection = buildCalendarProjection({ primaryUserId: 'p', partnerUserId: 'm', occurrences: [], tasks: [
      task({ id: 'pickup', category: 'pickup', definition_code: 'pickup', planned_assignee_id: 'm' }),
    ] });
    expect(transportCompactToken(pickupProjection.transportByDate.get('2026-08-24'), 'p', 'm')).toBe('迎M');
  });

  it('projects a multi-day Google all-day event onto every visible covered date', () => {
    const projection = buildCalendarProjection({
      primaryUserId: 'p', partnerUserId: 'm', tasks: [],
      occurrences: [{
        id: 'camp', date: '2026-08-24', allDayEndExclusive: '2026-08-27', time: null,
        title: '夏季休園', allDay: true, transparent: true, ownerUserId: null,
        providerEventId: 'event-camp', generatedByFamilyOps: false, hasConflict: false,
      }],
    });
    expect([...projection.itemsByDate.keys()]).toEqual(['2026-08-24', '2026-08-25', '2026-08-26']);
    expect(projection.itemsByDate.get('2026-08-25')?.[0]).toMatchObject({
      id: 'google:camp:2026-08-25', fullTitle: '夏季休園', allDay: true,
    });
  });

  it('projects a canonical Family Event without pretending it is Google or a task mirror', () => {
    const projection = buildCalendarProjection({
      primaryUserId: 'p', partnerUserId: 'm', tasks: [],
      occurrences: [{
        id: 'nursery-event', familyEventId: 'nursery-event', source: 'family_ops',
        date: '2026-10-08', time: null, title: '秋の遠足', allDay: true,
        allDayEndExclusive: '2026-10-09', transparent: false, ownerUserId: null,
        providerEventId: null, generatedByFamilyOps: false, hasConflict: false,
        location: '中央公園', sourceCalendar: 'おうちノート',
      }],
    });
    expect(projection.itemsByDate.get('2026-10-08')).toEqual([
      expect.objectContaining({
        id: 'family-event:nursery-event', source: 'family_ops', kind: 'calendar',
        fullTitle: '秋の遠足', location: '中央公園', providerEventId: null, linkedTaskId: null,
      }),
    ]);
  });
});
