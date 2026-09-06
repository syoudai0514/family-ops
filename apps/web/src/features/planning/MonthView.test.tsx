import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { MonthView } from './MonthView';

vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({
    household: { id: 'hh' },
    members: [
      { user_id: 'p', family_role: 'papa', profile: { display_name: 'パパ' } },
      { user_id: 'm', family_role: 'mama', profile: { display_name: 'ママ' } },
    ],
  }),
}));

vi.mock('./usePlanningData', () => ({
  usePlanningData: () => ({
    loading: false,
    error: null,
    refresh: vi.fn(),
    occurrences: [
      {
        id: 'event-6', date: '2026-09-06', time: null, title: '家族予定', allDay: true,
        transparent: true, ownerUserId: null, providerEventId: null,
        generatedByFamilyOps: false, hasConflict: false,
      },
    ],
    tasks: [
      {
        id: 'dropoff-6', household_id: 'hh', task_definition_id: 'd1', recurrence_rule_id: null,
        definition_code: 'dropoff', origin: 'recurring', title: '送り', category: 'dropoff',
        routine_phase: 'morning', scheduled_date: '2026-09-06', due_at: null,
        planned_assignee_id: 'p', completion_mode: 'whole', status: 'todo',
        actual_completed_by_id: null, completed_at: null,
      },
      {
        id: 'pickup-6', household_id: 'hh', task_definition_id: 'd2', recurrence_rule_id: null,
        definition_code: 'pickup', origin: 'recurring', title: '迎え', category: 'pickup',
        routine_phase: 'evening', scheduled_date: '2026-09-06', due_at: null,
        planned_assignee_id: 'm', completion_mode: 'whole', status: 'todo',
        actual_completed_by_id: null, completed_at: null,
      },
      {
        id: 'prep-6', household_id: 'hh', task_definition_id: null, recurrence_rule_id: null,
        origin: 'manual', title: '水着を準備', category: 'preparation', routine_phase: 'anytime',
        scheduled_date: '2026-09-06', due_at: null, planned_assignee_id: 'p',
        completion_mode: 'whole', status: 'todo', actual_completed_by_id: null, completed_at: null,
      },
    ],
  }),
}));

vi.mock('./DayAgendaSheet', () => ({
  DayAgendaSheet: ({ date }: { date: string }) => <div data-testid="day-agenda-sheet">detail:{date}</div>,
}));

vi.mock('./TransportOccurrenceOverrideModal', () => ({
  TransportOccurrenceOverrideModal: ({ date }: { date: string }) => <div data-testid="transport-override-modal">override:{date}</div>,
}));

vi.mock('../tasks/TaskFormModal', () => ({
  TaskFormModal: ({ initialScheduledDate }: { initialScheduledDate?: string }) => (
    <div data-testid="task-form-modal">add:{initialScheduledDate}</div>
  ),
}));

describe('MonthView inline day contract', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-09-05T10:00:00+09:00'));
  });
  afterEach(() => vi.useRealTimers());

  it('selects a date inline first, then opens detail, add, or one-day transport edit from the summary', () => {
    render(<MonthView />);

    expect(screen.queryByTestId('day-agenda-sheet')).not.toBeInTheDocument();
    expect(screen.queryByTestId('task-form-modal')).not.toBeInTheDocument();
    expect(screen.queryByTestId('transport-override-modal')).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '2026-09-06を選択' }));

    expect(screen.getByText('9/6 の予定')).toBeInTheDocument();
    expect(screen.getAllByText('家族予定').length).toBeGreaterThan(0);
    expect(screen.getByText('送り：パパ / 迎え：ママ')).toBeInTheDocument();
    expect(screen.getByText('水着を準備')).toBeInTheDocument();
    expect(screen.getAllByText('送P迎M').length).toBeGreaterThan(0);
    expect(screen.queryByTestId('day-agenda-sheet')).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '詳しく見る・編集' }));
    expect(screen.getByTestId('day-agenda-sheet')).toHaveTextContent('detail:2026-09-06');

    fireEvent.click(screen.getByRole('button', { name: 'この日に追加' }));
    expect(screen.getByTestId('task-form-modal')).toHaveTextContent('add:2026-09-06');

    fireEvent.click(screen.getByRole('button', { name: 'この日だけ変更' }));
    expect(screen.getByTestId('transport-override-modal')).toHaveTextContent('override:2026-09-06');
  });
});
