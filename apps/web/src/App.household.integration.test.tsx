import { render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import App from './App';

type FixtureRow = Record<string, unknown>;

const fixtureState = vi.hoisted(() => ({
  session: { user: { id: 'user-1' } },
  tables: {
    household_members: [
      {
        household_id: 'household-1',
        user_id: 'user-1',
        member_role: 'primary',
        joined_at: '2026-08-01T00:00:00Z',
      },
      {
        household_id: 'household-1',
        user_id: 'user-2',
        member_role: 'partner',
        joined_at: '2026-08-02T00:00:00Z',
      },
    ] as FixtureRow[],
    households: [
      {
        id: 'household-1',
        name: 'テスト家庭',
        timezone: 'Asia/Tokyo',
        dropoff_pickup_setup_completed_at: '2026-08-01T00:00:00Z',
        evening_routine_setup_completed_at: '2026-08-01T00:00:00Z',
      },
    ] as FixtureRow[],
    profiles: [
      { user_id: 'user-1', display_name: '本人' },
      { user_id: 'user-2', display_name: 'パートナー' },
    ] as FixtureRow[],
    task_instances: [] as FixtureRow[],
    task_subtask_instances: [] as FixtureRow[],
    requests: [] as FixtureRow[],
    handovers: [] as FixtureRow[],
    handover_reads: [] as FixtureRow[],
    shopping_items: [] as FixtureRow[],
  } as Record<string, FixtureRow[]>,
}));

vi.mock('./lib/supabaseClient', () => {
  function queryFor(table: string) {
    const rows = fixtureState.tables[table] ?? [];
    const builder = {
      select: vi.fn(() => builder),
      eq: vi.fn(() => builder),
      in: vi.fn(() => builder),
      order: vi.fn(() => builder),
      gte: vi.fn(() => builder),
      maybeSingle: vi.fn(() => Promise.resolve({ data: rows[0] ?? null, error: null })),
      then: (
        resolve: (value: { data: FixtureRow[]; error: null }) => unknown,
        reject?: (reason: unknown) => unknown,
      ) => Promise.resolve({ data: rows, error: null }).then(resolve, reject),
    };
    return builder;
  }

  const channel = {
    on: vi.fn(() => channel),
    subscribe: vi.fn(() => channel),
  };

  return {
    supabase: {
      auth: {
        getSession: vi.fn(() => Promise.resolve({ data: { session: fixtureState.session } })),
        onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
        signOut: vi.fn(() => Promise.resolve({ error: null })),
      },
      from: vi.fn((table: string) => queryFor(table)),
      channel: vi.fn(() => channel),
      removeChannel: vi.fn(),
    },
  };
});

vi.mock('./lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('./lib/apiClient')>('./lib/apiClient');
  return {
    ...actual,
    callEdgeFunction: vi.fn((name: string) => {
      if (name === 'get-today-schedule') {
        return Promise.resolve({
          household_id: 'household-1',
          local_date: '2026-08-21',
          calendar_connected: false,
          calendar_stale: false,
          occurrences: [],
          assignments: [],
        });
      }
      if (name === 'list-pending-actions') return Promise.resolve([]);
      return Promise.resolve({});
    }),
  };
});

describe('App household integration', () => {
  beforeEach(() => {
    window.localStorage.clear();
    window.localStorage.setItem('sb-dnlqxjpjpkxnfgculzip-auth-token', 'stored-session');
    window.history.replaceState({}, '', '/');
  });

  it('renders the real AuthenticatedApp, HouseholdProvider, HouseholdGate, AppShell, and Today path for a stored session', async () => {
    render(<App />);

    await waitFor(
      () => {
        expect(screen.getByRole('heading', { name: '今日' })).toBeInTheDocument();
      },
      { timeout: 5_000 },
    );
    expect(screen.queryByText('判断待ち')).not.toBeInTheDocument();
    expect(screen.queryByTestId('app-error-diagnostic')).not.toBeInTheDocument();
  });
});
