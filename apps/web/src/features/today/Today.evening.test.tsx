import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Today } from './Today';

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

const completedMorning = {
  id: 'morning-done', household_id: 'household-1', task_definition_id: null, recurrence_rule_id: null,
  origin: 'recurring', title: '朝の洗濯', category: 'routine', task_kind: 'morning_chore', routine_phase: 'morning',
  scheduled_date: '2026-09-05', due_at: null, planned_assignee_id: 'user-1', completion_mode: 'whole',
  status: 'completed', actual_completed_by_id: 'user-1', completed_at: '2026-09-05T07:00:00+09:00',
};
const unresolvedMorning = {
  ...completedMorning,
  id: 'morning-problem', title: '朝の薬を確認', planned_assignee_id: null,
  status: 'todo', actual_completed_by_id: null, completed_at: null,
};

vi.mock('./useTodayData', () => ({
  useTodayData: () => ({
    loading: false,
    error: null,
    tasks: [completedMorning, unresolvedMorning],
    carryoverTasks: [],
    subtasksByTaskId: new Map(),
    incomingRequests: [],
    unreadHandovers: [],
    openShoppingItems: [],
    briefSchedule: [],
    refresh: vi.fn(),
  }),
}));

vi.mock('./usePendingActions', () => ({
  usePendingActions: () => ({ pendingActions: [], error: null, confirm: vi.fn(), cancel: vi.fn(), update: vi.fn() }),
}));
vi.mock('./useTodaySchedule', () => ({
  useTodaySchedule: () => ({ loading: false, error: null, schedule: null }),
}));
vi.mock('../checkin/useCurrentRoutineSessions', () => ({
  useCurrentRoutineSessions: () => ({ sessions: [], error: null }),
}));
vi.mock('../planning/usePlanningData', () => ({
  usePlanningData: () => ({ loading: true, error: null, tasks: [], occurrences: [], refresh: vi.fn() }),
}));

vi.mock('./TodayTaskItem', () => ({
  TodayTaskItem: ({ task }: { task: { title: string } }) => <li>{task.title}</li>,
}));
vi.mock('./TodaySchedule', () => ({ TodaySchedule: () => null }));
vi.mock('./TomorrowPreparationCard', () => ({ TomorrowPreparationCard: () => null }));
vi.mock('./PendingActionCard', () => ({ PendingActionCard: () => null }));
vi.mock('./PendingActionEditModal', () => ({ PendingActionEditModal: () => null }));
vi.mock('../tasks/TaskFormModal', () => ({ TaskFormModal: () => null }));
vi.mock('../tasks/QuickAdd', () => ({ QuickAdd: () => <button type="button">追加</button> }));

// Q87: 夜は朝完了タスクを再掲せず「朝 n/n完了」程度。問題だけ具体表示。
describe('Today Q87 evening collapse', () => {
  afterEach(() => vi.restoreAllMocks());

  it('collapses completed morning work to n/n and keeps only unresolved morning problems concrete', () => {
    vi.spyOn(Date.prototype, 'getHours').mockReturnValue(20);
    render(<MemoryRouter><Today /></MemoryRouter>);

    expect(screen.getByRole('heading', { name: '朝の定例家事 1/2完了' })).toBeInTheDocument();
    expect(screen.queryByText('朝の洗濯')).not.toBeInTheDocument();
    expect(screen.getByText('朝の薬を確認')).toBeInTheDocument();
  });
});
