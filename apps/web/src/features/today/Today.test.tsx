import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';
import { createSupabaseFromMock } from '../../test/supabaseMock';
import { Today } from './Today';
import type { PendingAction, TodaySchedule } from '../../lib/types';

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    auth: {
      getSession: () => Promise.resolve({ data: { session: { access_token: 'test-token' } } }),
    },
    from: createSupabaseFromMock({
      task_instances: [
        {
          id: 'task-1',
          household_id: 'household-1',
          task_definition_id: null,
          recurrence_rule_id: null,
          origin: 'manual',
          title: '牛乳を買う',
          category: 'shopping',
          routine_phase: 'anytime',
          scheduled_date: '2026-08-19',
          due_at: null,
          planned_assignee_id: 'user-1',
          completion_mode: 'whole',
          status: 'todo',
          actual_completed_by_id: null,
          completed_at: null,
        },
      ],
      requests: [],
      handovers: [],
      handover_reads: [],
      shopping_items: [],
    }),
    channel: vi.fn(() => {
      const channelObj = {
        on: () => channelObj,
        subscribe: () => channelObj,
      };
      return channelObj;
    }),
    removeChannel: vi.fn(),
  },
}));

// Sol re-review #3 fix (P1-1/P1-2): Today now also calls list-pending-actions
// and get-today-schedule (both Edge Functions, not `.from()` reads — see
// docs/adr/0011). Real callEdgeFunction is replaced here rather than mocking
// fetch, matching how a component-level test should stay agnostic of the
// HTTP transport; FamilyOpsApiError is re-exported for real so `instanceof`
// checks inside the components under test still work correctly.
const PENDING_ACTIONS: PendingAction[] = [
  {
    id: 'pending-1',
    action_type: 'shopping_item_add',
    normalized_payload: { title: 'オムツ', purchase_method: 'online' },
    status: 'draft',
    source: 'line',
    expires_at: '2026-08-20T12:00:00Z',
    created_at: '2026-08-20T11:00:00Z',
  },
];

const TODAY_SCHEDULE: TodaySchedule = {
  household_id: 'household-1',
  local_date: '2026-08-19',
  calendar_connected: true,
  calendar_stale: false,
  occurrences: [],
  assignments: [
    {
      task_instance_id: 'task-pickup',
      title: 'お迎え',
      category: 'pickup',
      due_at: '2026-08-19T08:30:00Z',
      planned_assignee_id: 'user-1',
      has_conflict: true,
    },
  ],
};

vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return {
    ...actual,
    callEdgeFunction: vi.fn((name: string) => {
      if (name === 'list-pending-actions') return Promise.resolve(PENDING_ACTIONS);
      if (name === 'get-today-schedule') return Promise.resolve(TODAY_SCHEDULE);
      return Promise.resolve({});
    }),
  };
});

vi.mock('../../app/AuthContext', () => ({
  useAuth: () => ({
    user: { id: 'user-1' },
    session: null,
    loading: false,
  }),
}));

vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({
    phase: 'ready',
    household: {
      id: 'household-1',
      name: 'テスト家庭',
      timezone: 'Asia/Tokyo',
      evening_routine_setup_completed_at: '2026-08-01T00:00:00Z',
      dropoff_pickup_setup_completed_at: '2026-08-01T00:00:00Z',
    },
    members: [{ household_id: 'household-1', user_id: 'user-1', member_role: 'primary', joined_at: '2026-01-01', profile: { user_id: 'user-1', display_name: '本人' } }],
    me: { household_id: 'household-1', user_id: 'user-1', member_role: 'primary', joined_at: '2026-01-01', profile: { user_id: 'user-1', display_name: '本人' } },
    partner: null,
    refresh: vi.fn(),
  }),
}));

describe('Today', () => {
  it('renders without crashing and shows the fetched task', async () => {
    render(<MemoryRouter><Today /></MemoryRouter>);
    await waitFor(() => {
      expect(screen.getByRole('heading', { name: '今日' })).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(screen.getAllByText('牛乳を買う')).toHaveLength(2);
    });
    expect(screen.getByText('次にやること')).toBeInTheDocument();
  });

  it('shows Priority 1 (今/次の予定) with the conflict warning from get-today-schedule', async () => {
    render(<MemoryRouter><Today /></MemoryRouter>);
    await waitFor(() => {
      expect(screen.getByRole('heading', { name: '今/次の予定' })).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(screen.getByText(/お迎え（担当: 本人）/)).toBeInTheDocument();
    });
    expect(screen.getByText('⚠ 予定と重複')).toBeInTheDocument();
  });

  it('shows Priority 2 (判断待ち) with the LINE-created pending action from list-pending-actions', async () => {
    render(<MemoryRouter><Today /></MemoryRouter>);
    await waitFor(() => {
      expect(screen.getByRole('heading', { name: '判断待ち' })).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(screen.getByText('オムツ')).toBeInTheDocument();
    });
    expect(screen.getByRole('button', { name: 'この内容で確定' })).toBeInTheDocument();
  });
});
