import { render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { createSupabaseFromMock } from '../../test/supabaseMock';
import { Today } from './Today';

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
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
  },
}));

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
    render(<Today />);
    await waitFor(() => {
      expect(screen.getByRole('heading', { name: '今日' })).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(screen.getByText('牛乳を買う')).toBeInTheDocument();
    });
  });
});
