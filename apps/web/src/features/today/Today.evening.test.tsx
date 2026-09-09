import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';
import { Today } from './Today';

const completedMorning = {
  id: 'morning-done', household_id: 'household-1', task_definition_id: null, recurrence_rule_id: null,
  origin: 'recurring', title: '朝の洗濯', category: 'routine', task_kind: 'morning_chore', routine_phase: 'morning',
  scheduled_date: '2026-09-09', due_at: null, planned_assignee_id: 'user-1', completion_mode: 'whole',
  status: 'completed', attention_state: 'active', actual_completed_by_id: 'user-1', completed_at: '2026-09-09T07:00:00+09:00',
};
const unresolvedMorning = {
  ...completedMorning,
  id: 'morning-problem', title: '朝の薬を確認', planned_assignee_id: null,
  status: 'todo', actual_completed_by_id: null, completed_at: null,
};

vi.mock('./useTodayClock', () => ({
  useTodayClock: () => ({
    now: new Date('2026-09-09T11:00:00Z'),
    localDate: '2026-09-09',
    daypart: 'evening' as const,
  }),
}));

vi.mock('../../app/AuthContext', () => ({
  useAuth: () => ({ user: { id: 'user-1' }, session: null, loading: false }),
}));

vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({
    household: { id: 'household-1', timezone: 'Asia/Tokyo' },
    members: [{
      household_id: 'household-1', user_id: 'user-1', member_role: 'adult', family_role: 'papa',
      joined_at: '2026-01-01', profile: { user_id: 'user-1', display_name: '本人' },
    }],
    me: { household_id: 'household-1', user_id: 'user-1', member_role: 'adult', family_role: 'papa', joined_at: '2026-01-01', profile: { user_id: 'user-1', display_name: '本人' } },
    partner: null,
  }),
}));

vi.mock('./useTodayData', () => ({
  useTodayData: () => ({
    status: 'ready', loading: false, refreshing: false, error: null, lastUpdatedAt: Date.now(),
    urgentActions: [],
    tasks: [unresolvedMorning],
    taskGroups: { morning: [unresolvedMorning], daytime: [], evening: [], optional: [] },
    waitingTasks: [], waitingRefsByTaskId: new Map(), carryoverTasks: [], alreadyHandledTasks: [completedMorning],
    subtasksByTaskId: new Map(), executionTargetsByTaskId: new Map(), incomingRequests: [], requestAttemptsByRequestId: new Map(),
    unreadHandovers: [], openShoppingItems: [], briefSchedule: [], partnerSummary: {},
    reconciliation: { sessions: [], remaining_count: 0, actionable: false },
    tomorrowImpact: { task_count: 0, schedule_count: 0, carryover_count: 0, impact_count: 0, tasks: [], schedule: [], carryovers: [] },
    morningSummary: { completedCount: 1, totalCount: 2 },
    refresh: vi.fn(),
  }),
}));

vi.mock('./usePendingActions', () => ({
  usePendingActions: () => ({ pendingActions: [], loading: false, error: null, confirm: vi.fn(), cancel: vi.fn(), update: vi.fn(), refresh: vi.fn() }),
}));
vi.mock('./TodayTaskItem', () => ({
  TodayTaskItem: ({ task }: { task: { title: string } }) => <li>{task.title}</li>,
}));
vi.mock('./TomorrowPreparationCard', () => ({ TomorrowPreparationCard: () => null }));
vi.mock('./PendingActionCard', () => ({ PendingActionCard: () => null }));
vi.mock('./PendingActionEditModal', () => ({ PendingActionEditModal: () => null }));
vi.mock('../tasks/TaskFormModal', () => ({ TaskFormModal: () => null }));
vi.mock('../tasks/QuickAdd', () => ({ QuickAdd: () => <button type="button">追加</button> }));

// Q87: 夜は未済を優先し、朝完了タスクは再掲せず「朝 n/n 完了」程度に畳む。
describe('Today Q87 evening collapse', () => {
  it('shows the server-owned morning completion summary and only the unresolved morning item concretely', () => {
    render(<MemoryRouter><Today /></MemoryRouter>);

    expect(screen.getByRole('heading', { name: '朝 1/2 完了' })).toBeInTheDocument();
    expect(screen.queryByText('朝の洗濯')).not.toBeInTheDocument();
    expect(screen.getByText('朝の薬を確認')).toBeInTheDocument();
  });
});