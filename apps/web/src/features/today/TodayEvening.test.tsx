import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Today } from './Today';

const morningTasks = [
  {
    id: 'morning-done', household_id: 'household-1', title: '朝の連絡帳', category: 'routine', task_kind: 'morning_preparation',
    routine_phase: 'morning', scheduled_date: '2026-09-05', planned_assignee_id: 'user-1', completion_mode: 'whole', status: 'completed',
    origin: 'routine', task_definition_id: null, recurrence_rule_id: null, due_at: null, actual_completed_by_id: 'user-1', completed_at: '2026-09-05T08:00:00+09:00',
  },
  {
    id: 'morning-open', household_id: 'household-1', title: '朝の水筒', category: 'routine', task_kind: 'morning_preparation',
    routine_phase: 'morning', scheduled_date: '2026-09-05', planned_assignee_id: 'user-1', completion_mode: 'whole', status: 'todo',
    origin: 'routine', task_definition_id: null, recurrence_rule_id: null, due_at: null, actual_completed_by_id: null, completed_at: null,
  },
];

vi.mock('./useTodayData', () => ({
  useTodayData: () => ({
    loading: false, error: null, tasks: morningTasks, carryoverTasks: [], subtasksByTaskId: new Map(), incomingRequests: [],
    unreadHandovers: [], openShoppingItems: [], briefSchedule: [], refresh: vi.fn(),
  }),
}));
vi.mock('./usePendingActions', () => ({ usePendingActions: () => ({ pendingActions: [], loading: false, error: null, refresh: vi.fn() }) }));
vi.mock('./useTodaySchedule', () => ({ useTodaySchedule: () => ({ schedule: null, loading: false, error: null, refresh: vi.fn() }) }));
vi.mock('../checkin/useCurrentRoutineSessions', () => ({ useCurrentRoutineSessions: () => ({ sessions: [], loading: false, error: null, refresh: vi.fn() }) }));
vi.mock('../planning/usePlanningData', () => ({ usePlanningData: () => ({ tasks: [], occurrences: [], loading: false, error: null }) }));
vi.mock('./TodayTaskItem', () => ({ TodayTaskItem: ({ task }: { task: { title: string } }) => <li>{task.title}</li> }));
vi.mock('./TodaySchedule', () => ({ TodaySchedule: () => null }));
vi.mock('./TomorrowPreparationCard', () => ({ TomorrowPreparationCard: () => null }));
vi.mock('./PendingActionCard', () => ({ PendingActionCard: () => null }));
vi.mock('./PendingActionEditModal', () => ({ PendingActionEditModal: () => null }));
vi.mock('../tasks/TaskFormModal', () => ({ TaskFormModal: () => null }));
vi.mock('../tasks/QuickAdd', () => ({ QuickAdd: () => <button type="button">追加</button> }));
vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return { ...actual, callEdgeFunction: vi.fn(() => Promise.resolve({})) };
});
vi.mock('../../app/AuthContext', () => ({ useAuth: () => ({ user: { id: 'user-1' } }) }));
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({
    household: { id: 'household-1' },
    members: [{ household_id: 'household-1', user_id: 'user-1', family_role: 'papa', profile: { display_name: 'パパ' } }],
    me: { user_id: 'user-1' }, partner: null,
  }),
}));

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date('2026-09-05T18:30:00'));
});
afterEach(() => vi.useRealTimers());

describe('Q87 evening Today collapse', () => {
  it('does not repeat completed morning rows and shows only the summary plus unfinished problem', () => {
    render(<MemoryRouter><Today /></MemoryRouter>);
    expect(screen.getByRole('heading', { name: '朝準備 1/2完了' })).toBeInTheDocument();
    expect(screen.queryByText('朝の連絡帳')).not.toBeInTheDocument();
    expect(screen.getByText('朝の水筒')).toBeInTheDocument();
  });
});
