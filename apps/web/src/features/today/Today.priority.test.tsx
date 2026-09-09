import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Today } from './Today';
import { useTodayData } from './useTodayData';
import { usePendingActions } from './usePendingActions';
import { useTodayClock } from './useTodayClock';

vi.mock('./useTodayData', () => ({ useTodayData: vi.fn() }));
vi.mock('./usePendingActions', () => ({ usePendingActions: vi.fn() }));
vi.mock('./useTodayClock', () => ({ useTodayClock: vi.fn() }));
vi.mock('./TodayTaskItem', () => ({ TodayTaskItem: ({ task }: { task: { title: string } }) => <li>{task.title}</li> }));
vi.mock('./TomorrowPreparationCard', () => ({ TomorrowPreparationCard: () => null }));
vi.mock('./PendingActionCard', () => ({ PendingActionCard: ({ action }: { action: { id: string } }) => <li>{action.id}</li> }));
vi.mock('./PendingActionEditModal', () => ({ PendingActionEditModal: () => null }));
vi.mock('../tasks/TaskFormModal', () => ({ TaskFormModal: () => null }));
vi.mock('../tasks/QuickAdd', () => ({ QuickAdd: () => null }));
vi.mock('../../app/AuthContext', () => ({ useAuth: () => ({ user: { id: 'user-1' } }) }));
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ household: { id: 'household-1' }, members: [], partner: null }),
}));
vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return { ...actual, callEdgeFunction: vi.fn() };
});

const task = (id: string, title: string) => ({
  id, household_id: 'household-1', task_definition_id: null, recurrence_rule_id: null,
  origin: 'manual', title, category: 'other', task_kind: 'generic_once', routine_phase: 'anytime',
  scheduled_date: '2026-09-09', due_at: null, planned_assignee_id: 'user-1', completion_mode: 'whole',
  status: 'todo', attention_state: 'active', actual_completed_by_id: null, completed_at: null,
});

const morning = task('morning-1', '朝の残り');
const evening = task('evening-1', '夜の残り');
const waiting = { ...task('waiting-1', '返事待ち'), attention_state: 'waiting' };

function data(overrides: Record<string, unknown> = {}) {
  return {
    status: 'ready', loading: false, refreshing: false, error: null, lastUpdatedAt: Date.now(),
    urgentActions: [{ kind: 'assignment_needed', task_id: 'urgent-1', title: '担当を決める' }],
    tasks: [morning, evening],
    taskGroups: { morning: [morning], daytime: [], evening: [evening], optional: [] },
    waitingTasks: [waiting], waitingRefsByTaskId: new Map(), carryoverTasks: [], alreadyHandledTasks: [],
    subtasksByTaskId: new Map(), executionTargetsByTaskId: new Map(), incomingRequests: [], requestAttemptsByRequestId: new Map(),
    unreadHandovers: [], openShoppingItems: [], briefSchedule: [], partnerSummary: {},
    reconciliation: { sessions: [], remaining_count: 0, actionable: false },
    tomorrowImpact: {
      local_date: '2026-09-10', task_count: 1, schedule_count: 1, carryover_count: 0, impact_count: 2,
      tasks: [{ task_id: 'tomorrow-1', title: '明日の準備' }],
      schedule: [{ kind: 'family_event', family_event_id: 'event-1', occurrence_key: null, title: '明日の予定', is_all_day: true, starts_at: null, ends_at: null, all_day_start: '2026-09-10', all_day_end_exclusive: '2026-09-11' }],
      carryovers: [],
    },
    morningSummary: { completedCount: 1, totalCount: 2 },
    refresh: vi.fn(async () => undefined),
    ...overrides,
  } as unknown as ReturnType<typeof useTodayData>;
}

const pendingBase = {
  pendingActions: [{ id: 'pending-1', normalized_payload: {}, status: 'draft' }],
  loading: false, error: null,
  confirm: vi.fn(), cancel: vi.fn(), update: vi.fn(), refresh: vi.fn(),
} as unknown as ReturnType<typeof usePendingActions>;

const mockToday = vi.mocked(useTodayData);
const mockPending = vi.mocked(usePendingActions);
const mockClock = vi.mocked(useTodayClock);

describe('Today first-flow priority contract', () => {
  beforeEach(() => {
    mockToday.mockReturnValue(data());
    mockPending.mockReturnValue(pendingBase);
    mockClock.mockReturnValue({ now: new Date('2026-09-09T11:00:00Z'), localDate: '2026-09-09', daypart: 'evening' });
  });

  it('keeps 要対応 / 残り / 待ち / 明日影響 visible before the detailed flow and preserves evening priority', () => {
    render(<MemoryRouter><Today /></MemoryRouter>);

    const summary = screen.getByRole('region', { name: '今日の重要サマリー' });
    expect(summary).toHaveTextContent('要対応 2');
    expect(summary).toHaveTextContent('残り 2');
    expect(summary).toHaveTextContent('待ち 1');
    expect(summary).toHaveTextContent('明日影響 2');

    const waitingSection = screen.getByRole('region', { name: '待ち・確認' });
    const remainingHeading = screen.getByRole('heading', { name: 'まだ残っていること' });
    const tomorrowSection = screen.getByRole('region', { name: '明日に影響' });
    const morningSummary = screen.getByRole('region', { name: '朝の完了まとめ' });
    expect(waitingSection.compareDocumentPosition(remainingHeading) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(tomorrowSection.compareDocumentPosition(morningSummary) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it('does not render the Empty success surface while the separate pending-action controller is still loading', () => {
    mockToday.mockReturnValue(data({
      status: 'empty', urgentActions: [], tasks: [],
      taskGroups: { morning: [], daytime: [], evening: [], optional: [] }, waitingTasks: [],
      tomorrowImpact: { task_count: 0, schedule_count: 0, carryover_count: 0, impact_count: 0, tasks: [], schedule: [], carryovers: [] },
      morningSummary: { completedCount: 0, totalCount: 0 },
    }));
    mockPending.mockReturnValue({ ...pendingBase, pendingActions: [], loading: true });
    const view = render(<MemoryRouter><Today /></MemoryRouter>);
    expect(screen.queryByRole('heading', { name: '今日は確認が必要な項目はありません' })).not.toBeInTheDocument();

    mockPending.mockReturnValue({ ...pendingBase, pendingActions: [], loading: false });
    view.rerender(<MemoryRouter><Today /></MemoryRouter>);
    expect(screen.getByRole('heading', { name: '今日は確認が必要な項目はありません' })).toBeInTheDocument();
  });
});
