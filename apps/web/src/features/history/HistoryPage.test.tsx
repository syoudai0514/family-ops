import { render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { createSupabaseFromMock } from '../../test/supabaseMock';
import { HistoryPage } from './HistoryPage';

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
          title: 'お迎え',
          category: 'pickup',
          routine_phase: 'anytime',
          scheduled_date: '2026-08-18',
          due_at: '2026-08-18T09:00:00Z',
          planned_assignee_id: 'user-1',
          completion_mode: 'whole',
          status: 'completed',
          actual_completed_by_id: 'user-2',
          completed_at: '2026-08-18T10:30:00Z',
        },
        {
          id: 'task-2',
          household_id: 'household-1',
          task_definition_id: null,
          recurrence_rule_id: null,
          origin: 'manual',
          title: '洗濯物をたたむ',
          category: 'laundry',
          routine_phase: 'evening',
          scheduled_date: '2026-08-17',
          due_at: null,
          planned_assignee_id: 'user-2',
          completion_mode: 'whole',
          status: 'skipped',
          actual_completed_by_id: null,
          completed_at: null,
        },
      ],
      task_events: [
        {
          id: 'event-1',
          household_id: 'household-1',
          task_instance_id: 'task-1',
          actor_id: 'user-2',
          event_type: 'reassigned_once',
          payload: { old_assignee_id: 'user-1', new_assignee_id: 'user-2' },
          source: 'pwa',
          idempotency_key: null,
          created_at: '2026-08-18T08:00:00Z',
        },
        {
          id: 'event-2',
          household_id: 'household-1',
          task_instance_id: 'task-1',
          actor_id: 'user-2',
          event_type: 'completed',
          payload: {},
          source: 'pwa',
          idempotency_key: null,
          created_at: '2026-08-18T10:30:00Z',
        },
      ],
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
      morning_preparation_setup_completed_at: '2026-08-01T00:00:00Z',
      connections_setup_completed_at: '2026-08-01T00:00:00Z',
      notification_preferences_setup_completed_at: '2026-08-01T00:00:00Z',
      onboarding_preview_completed_at: '2026-08-01T00:00:00Z',
    },
    members: [
      { household_id: 'household-1', user_id: 'user-1', member_role: 'primary', joined_at: '2026-01-01', profile: { user_id: 'user-1', display_name: '本人' } },
      { household_id: 'household-1', user_id: 'user-2', member_role: 'partner', joined_at: '2026-01-01', profile: { user_id: 'user-2', display_name: 'パートナー' } },
    ],
    me: { household_id: 'household-1', user_id: 'user-1', member_role: 'primary', joined_at: '2026-01-01', profile: { user_id: 'user-1', display_name: '本人' } },
    partner: { household_id: 'household-1', user_id: 'user-2', member_role: 'partner', joined_at: '2026-01-01', profile: { user_id: 'user-2', display_name: 'パートナー' } },
    refresh: vi.fn(),
  }),
}));

describe('HistoryPage', () => {
  it('renders planned-vs-actual entries for the household, with no score/ranking UI', async () => {
    render(<HistoryPage />);

    await waitFor(() => {
      expect(screen.getByRole('heading', { name: '履歴' })).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(screen.getByText('お迎え')).toBeInTheDocument();
    });

    // Planned vs actual outcome labels.
    expect(screen.getByText('完了（期限超過）')).toBeInTheDocument();
    expect(screen.getByText('スキップ')).toBeInTheDocument();

    // Reassignment shows up as a plain fact, not a comparison.
    expect(screen.getByText('この予定は再割り当てされました。')).toBeInTheDocument();

    // No score/ranking vocabulary anywhere on the page.
    expect(screen.queryByText(/スコア|ランキング|ポイント/)).not.toBeInTheDocument();
  });
});
