import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Today } from './Today';
import { useTodayData, type TodayData } from './useTodayData';
import { usePendingActions } from './usePendingActions';

vi.mock('./useTodayData', () => ({ useTodayData: vi.fn() }));
vi.mock('./usePendingActions', () => ({ usePendingActions: vi.fn() }));
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
const mockUsePendingActions = vi.mocked(usePendingActions);
const refresh = vi.fn(async () => undefined);

function todayData(overrides: Partial<TodayData> = {}): TodayData {
  return {
    status: 'empty',
    loading: false,
    refreshing: false,
    error: null,
    lastUpdatedAt: Date.now(),
    urgentActions: [],
    exceptions: [],
    tasks: [],
    taskGroups: { morning: [], daytime: [], evening: [], optional: [] },
    waitingTasks: [],
    waitingRefsByTaskId: new Map(),
    carryoverTasks: [],
    alreadyHandledTasks: [],
    subtasksByTaskId: new Map(),
    executionTargetsByTaskId: new Map(),
    incomingRequests: [],
    requestAttemptsByRequestId: new Map(),
    unreadHandovers: [],
    openShoppingItems: [],
    briefSchedule: [],
    partnerSummary: {},
    reconciliation: { sessions: [], remaining_count: 0, actionable: false },
    tomorrowImpact: {
      task_count: 0,
      schedule_count: 0,
      carryover_count: 0,
      impact_count: 0,
      tasks: [],
      schedule: [],
      carryovers: [],
    },
    morningSummary: { completedCount: 0, totalCount: 0 },
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
    mockUsePendingActions.mockReturnValue({
      loading: false,
      error: null,
      pendingActions: [],
      confirm: refresh,
      cancel: refresh,
      update: vi.fn(async () => undefined),
      refresh,
    });
  });

  it('renders the actual Today loading surface while canonical Today data is pending', () => {
    mockUseTodayData.mockReturnValue(todayData({ status: 'loading', loading: true, lastUpdatedAt: null }));
    renderToday();

    expect(screen.getByRole('status')).toHaveTextContent('読み込み中…');
    expect(screen.queryByRole('heading', { name: '今日' })).not.toBeInTheDocument();
  });

  it('renders the actual Today error surface without converting the failed read into empty success', () => {
    mockUseTodayData.mockReturnValue(todayData({
      status: 'error',
      error: '今日の情報を読み込めませんでした。',
      lastUpdatedAt: null,
    }));
    renderToday();

    expect(screen.getByRole('alert')).toHaveTextContent('今日の情報を読み込めませんでした。');
    expect(screen.getByRole('heading', { name: '今日' })).toBeInTheDocument();
  });

  it('renders stale canonical Today data as an explicit warning while retaining the usable surface', () => {
    mockUseTodayData.mockReturnValue(todayData({
      status: 'stale',
      error: '読み込みに失敗しました。',
      lastUpdatedAt: Date.now() - 30_000,
    }));
    renderToday();

    expect(screen.getByRole('status')).toHaveTextContent('通信が不安定なため、最後に取得できた内容を表示しています。');
    expect(screen.getByRole('alert')).toHaveTextContent('読み込みに失敗しました。');
    expect(screen.getByRole('heading', { name: '今日' })).toBeInTheDocument();
  });
});
