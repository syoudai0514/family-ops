import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Today } from './Today';
import { useTodayData } from './useTodayData';
import { useTodaySchedule } from './useTodaySchedule';
import { usePendingActions } from './usePendingActions';
import { useCurrentRoutineSessions } from '../checkin/useCurrentRoutineSessions';
import { usePlanningData } from '../planning/usePlanningData';

vi.mock('./useTodayData', () => ({ useTodayData: vi.fn() }));
vi.mock('./useTodaySchedule', () => ({ useTodaySchedule: vi.fn() }));
vi.mock('./usePendingActions', () => ({ usePendingActions: vi.fn() }));
vi.mock('../checkin/useCurrentRoutineSessions', () => ({ useCurrentRoutineSessions: vi.fn() }));
vi.mock('../planning/usePlanningData', () => ({ usePlanningData: vi.fn() }));
vi.mock('../tasks/QuickAdd', () => ({ QuickAdd: () => null }));
vi.mock('../../app/AuthContext', () => ({
  useAuth: () => ({ user: { id: 'user-1' }, session: null, loading: false }),
}));
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({
    phase: 'ready',
    household: { id: 'household-1', name: 'テスト家庭', timezone: 'Asia/Tokyo' },
    members: [],
    me: { user_id: 'user-1' },
    partner: null,
    refresh: vi.fn(),
  }),
}));

const mockUseTodayData = vi.mocked(useTodayData);
const mockUseTodaySchedule = vi.mocked(useTodaySchedule);
const mockUsePendingActions = vi.mocked(usePendingActions);
const mockUseCurrentRoutineSessions = vi.mocked(useCurrentRoutineSessions);
const mockUsePlanningData = vi.mocked(usePlanningData);

const refresh = vi.fn(async () => undefined);

function todayData(overrides: Partial<ReturnType<typeof useTodayData>> = {}): ReturnType<typeof useTodayData> {
  return {
    loading: false,
    error: null,
    tasks: [],
    carryoverTasks: [],
    subtasksByTaskId: new Map(),
    executionTargetsByTaskId: new Map(),
    incomingRequests: [],
    unreadHandovers: [],
    openShoppingItems: [],
    briefSchedule: [],
    refresh,
    ...overrides,
  };
}

function renderToday() {
  return render(
    <MemoryRouter>
      <Today />
    </MemoryRouter>,
  );
}

describe('CF-14 Today user-visible state evidence', () => {
  beforeEach(() => {
    refresh.mockClear();
    mockUseTodayData.mockReturnValue(todayData());
    mockUseTodaySchedule.mockReturnValue({ loading: false, error: null, schedule: null, refresh });
    mockUsePendingActions.mockReturnValue({
      loading: false,
      error: null,
      pendingActions: [],
      confirm: refresh,
      cancel: refresh,
      update: vi.fn(async () => undefined),
      refresh,
    });
    mockUseCurrentRoutineSessions.mockReturnValue({ sessions: [], loading: false, error: null, refresh });
    mockUsePlanningData.mockReturnValue({
      tasks: [],
      occurrences: [],
      loading: false,
      error: null,
      refresh,
    });
  });

  it('renders the actual Today loading surface while canonical Today data is pending', () => {
    mockUseTodayData.mockReturnValue(todayData({ loading: true }));
    renderToday();

    expect(screen.getByRole('status')).toHaveTextContent('読み込み中…');
    expect(screen.queryByRole('heading', { name: '今日' })).not.toBeInTheDocument();
  });

  it('renders the actual Today error surface without converting the failed read into empty success', () => {
    mockUseTodayData.mockReturnValue(todayData({ error: '今日の情報を読み込めませんでした' }));
    renderToday();

    expect(screen.getByRole('alert')).toHaveTextContent('今日の情報を読み込めませんでした');
    expect(screen.getByRole('heading', { name: '今日' })).toBeInTheDocument();
  });

  it('renders stale Google schedule as an explicit warning on the actual Today surface', () => {
    mockUseTodaySchedule.mockReturnValue({
      loading: false,
      error: null,
      schedule: {
        household_id: 'household-1',
        local_date: '2026-09-09',
        calendar_connected: true,
        calendar_stale: true,
        occurrences: [],
        assignments: [],
      },
      refresh,
    });
    renderToday();

    expect(screen.getByRole('alert')).toHaveTextContent('Google予定を最新化できていません');
    expect(screen.getByRole('heading', { name: '今/次の予定' })).toBeInTheDocument();
  });
});
