import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';
import { Today } from './Today';

const morningOpen = {
  id: 'morning-open', household_id: 'household-1', title: '朝の水筒', category: 'routine', task_kind: 'morning_preparation',
  routine_phase: 'morning', scheduled_date: '2026-09-09', planned_assignee_id: 'user-1', completion_mode: 'whole', status: 'todo',
  attention_state: 'active', origin: 'routine', task_definition_id: null, recurrence_rule_id: null, due_at: null,
  actual_completed_by_id: null, completed_at: null,
};

vi.mock('./useTodayClock', () => ({
  useTodayClock: () => ({ now: new Date('2026-09-09T08:00:00Z'), localDate: '2026-09-09', daypart: 'evening' as const }),
}));
vi.mock('./useTodayData', () => ({
  useTodayData: () => ({
    status: 'ready', loading: false, refreshing: false, error: null, lastUpdatedAt: Date.now(),
    urgentActions: [], exceptions: [], tasks: [morningOpen],
    taskGroups: { morning: [morningOpen], daytime: [], evening: [], optional: [] },
    waitingTasks: [], waitingRefsByTaskId: new Map(), carryoverTasks: [], alreadyHandledTasks: [],
    subtasksByTaskId: new Map(), executionTargetsByTaskId: new Map(), incomingRequests: [], requestAttemptsByRequestId: new Map(),
    unreadHandovers: [], openShoppingItems: [], briefSchedule: [], partnerSummary: {},
    reconciliation: { sessions: [], remaining_count: 0, actionable: false },
    tomorrowImpact: { task_count: 0, schedule_count: 0, carryover_count: 0, impact_count: 0, tasks: [], schedule: [], carryovers: [] },
    morningSummary: { completedCount: 1, totalCount: 2 }, refresh: vi.fn(),
  }),
}));
vi.mock('./usePendingActions', () => ({
  usePendingActions: () => ({ pendingActions: [], loading: false, error: null, confirm: vi.fn(), cancel: vi.fn(), update: vi.fn(), refresh: vi.fn() }),
}));
vi.mock('./TodayTaskItem', () => ({ TodayTaskItem: ({ task }: { task: { title: string } }) => <li>{task.title}</li> }));
vi.mock('./TomorrowPreparationCard', () => ({ TomorrowPreparationCard: () => null }));
vi.mock('./PendingActionCard', () => ({ PendingActionCard: () => null }));
vi.mock('./PendingActionEditModal', () => ({ PendingActionEditModal: () => null }));
vi.mock('../tasks/TaskFormModal', () => ({ TaskFormModal: () => null }));
vi.mock('../tasks/QuickAdd', () => ({ QuickAdd: () => <button type="button">追加</button> }));
vi.mock('../../app/AuthContext', () => ({ useAuth: () => ({ user: { id: 'user-1' } }) }));
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({
    household: { id: 'household-1' },
    members: [{ household_id: 'household-1', user_id: 'user-1', family_role: 'papa', profile: { display_name: 'パパ' } }],
    me: { user_id: 'user-1' }, partner: null,
  }),
}));

describe('Q87 evening Today compact summary', () => {
  it('keeps unfinished morning work concrete while completion history stays compact', () => {
    render(<MemoryRouter><Today /></MemoryRouter>);
    expect(screen.getByRole('heading', { name: '朝 1/2 完了' })).toBeInTheDocument();
    expect(screen.getByText('朝の水筒')).toBeInTheDocument();
  });
});
