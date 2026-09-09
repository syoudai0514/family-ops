import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';
import { createSupabaseFromMock } from '../../test/supabaseMock';
import {
  Today,
  isTodayRequestAttemptActionable,
  selectNextOwnedTask,
  shouldShowWaitingTask,
  todayRequestTransitionPayload,
} from './Today';
import type { TodayRequestAttempt } from './useTodayData';
import type { PendingAction, TaskInstance } from '../../lib/types';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';

const REQUEST_ATTEMPT: TodayRequestAttempt = {
  id: 'attempt-1',
  request_id: 'request-1',
  state: 'pending',
  revision: 3,
  terms_revision: 2,
  reply_due_at: '2099-09-10T12:00:00Z',
};

const taskRow = {
  id: 'task-1',
  household_id: 'household-1',
  task_definition_id: null,
  recurrence_rule_id: null,
  origin: 'manual',
  title: '牛乳を買う',
  category: 'shopping',
  task_kind: 'generic_once',
  routine_phase: 'anytime',
  scheduled_date: '2026-09-09',
  due_at: '2026-09-09T07:00:00Z',
  planned_assignee_id: 'user-1',
  completion_mode: 'whole',
  status: 'todo',
  attention_state: 'active',
  actual_completed_by_id: null,
  completed_at: null,
} as TaskInstance;

vi.mock('./useTodayClock', () => ({
  useTodayClock: () => ({
    now: new Date('2026-09-09T05:00:00Z'),
    localDate: '2026-09-09',
    daypart: 'day' as const,
  }),
}));

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    auth: {
      getSession: () => Promise.resolve({ data: { session: { access_token: 'test-token' } } }),
    },
    from: createSupabaseFromMock({
      task_instances: [taskRow],
      task_subtask_instances: [],
      task_execution_targets: [],
      requests: [
        {
          id: 'request-1',
          household_id: 'household-1',
          requester_id: 'user-2',
          recipient_id: 'user-1',
          shared_title: '迎えをお願い',
          shared_message: '今日の迎えをお願いします',
          due_at: '2099-09-11T12:00:00Z',
          status: 'pending',
          linked_task_instance_id: null,
          accepted_at: null,
          declined_at: null,
          completed_at: null,
          cancelled_at: null,
        },
      ],
      handovers: [],
      shopping_items: [],
    }),
    rpc: vi.fn((name: string) => {
      if (name === 'get_my_daily_brief') {
        return Promise.resolve({
          data: {
            tasks: [{ task_id: 'task-1' }],
            own_task_groups: {
              morning: [],
              daytime: [{ task_id: 'task-1' }],
              evening: [],
              optional: [],
            },
            carryover: [],
            carryovers: [],
            waiting_checks: [],
            already_handled: [],
            urgent_actions: [
              {
                request_id: 'request-1',
                attempt_id: 'attempt-1',
                state: 'pending',
                revision: 3,
                terms_revision: 2,
                reply_due_at: '2099-09-10T12:00:00Z',
              },
            ],
            handovers: [],
            active_infos: [],
            shopping: [],
            schedule: [
              {
                kind: 'family_event',
                family_event_id: 'event-1',
                title: '保育園面談',
                is_all_day: false,
                starts_at: '2026-09-09T06:30:00Z',
                ends_at: '2026-09-09T07:00:00Z',
                all_day_start: null,
                all_day_end_exclusive: null,
              },
            ],
            partner_summary: { open_assigned: 0, completed_today: 0, critical_items: [] },
            reconciliation: { sessions: [], remaining_count: 0, actionable: false },
            tomorrow_impact: {
              local_date: '2026-09-10',
              task_count: 0,
              schedule_count: 0,
              carryover_count: 0,
              impact_count: 0,
              tasks: [],
              schedule: [],
              carryovers: [],
            },
          },
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: null });
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

const PENDING_ACTIONS: PendingAction[] = [
  {
    id: 'pending-1',
    action_type: 'shopping_item_add',
    normalized_payload: { title: 'オムツ', purchase_method: 'online' },
    status: 'draft',
    source: 'line',
    expires_at: '2026-09-10T12:00:00Z',
    created_at: '2026-09-09T11:00:00Z',
  },
];

vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return {
    ...actual,
    callEdgeFunction: vi.fn((name: string) => {
      if (name === 'list-pending-actions') return Promise.resolve(PENDING_ACTIONS);
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
    },
    members: [
      {
        household_id: 'household-1',
        user_id: 'user-1',
        member_role: 'primary',
        family_role: 'papa',
        joined_at: '2026-01-01',
        profile: { user_id: 'user-1', display_name: '本人' },
      },
    ],
    me: {
      household_id: 'household-1',
      user_id: 'user-1',
      member_role: 'primary',
      family_role: 'papa',
      joined_at: '2026-01-01',
      profile: { user_id: 'user-1', display_name: '本人' },
    },
    partner: null,
    refresh: vi.fn(),
  }),
}));

describe('Today', () => {
  it('suppresses a waiting task until its future check date unless an immediate deadline is at risk', () => {
    const task: TaskInstance = {
      ...taskRow,
      id: 'waiting',
      title: '園からの返事',
      due_at: null,
      attention_state: 'waiting',
      next_check_at: '2026-09-11T00:00:00Z',
    };
    const now = new Date('2026-09-09T00:00:00Z');
    expect(shouldShowWaitingTask(task, now)).toBe(false);
    expect(shouldShowWaitingTask({ ...task, due_at: '2026-09-08T23:00:00Z' }, now)).toBe(true);
    expect(shouldShowWaitingTask({ ...task, next_check_at: null }, now)).toBe(true);
  });

  it('freezes the observed RequestAttempt snapshot used by Today actions', () => {
    expect(todayRequestTransitionPayload('request-1', REQUEST_ATTEMPT)).toEqual({
      request_id: 'request-1',
      attempt_id: 'attempt-1',
      expected_revision: 3,
      expected_terms_revision: 2,
    });
    expect(isTodayRequestAttemptActionable(REQUEST_ATTEMPT, new Date('2099-09-10T11:59:59Z').getTime())).toBe(true);
    expect(isTodayRequestAttemptActionable(REQUEST_ATTEMPT, new Date('2099-09-10T12:00:00Z').getTime())).toBe(false);
    expect(isTodayRequestAttemptActionable({ ...REQUEST_ATTEMPT, state: 'consulting' })).toBe(false);
  });

  it('selects my next task even when the partner has an earlier task', () => {
    const selected = selectNextOwnedTask(
      [
        { ...taskRow, id: 'partner', title: '相手の仕事', due_at: '2026-09-09T06:00:00Z', planned_assignee_id: 'user-2' },
        { ...taskRow, id: 'mine', title: '自分の仕事', due_at: '2026-09-09T07:00:00Z', planned_assignee_id: 'user-1' },
      ],
      'user-1',
    );
    expect(selected?.id).toBe('mine');
  });

  it('renders task groups and schedule supplied by DailyBrief', async () => {
    render(<MemoryRouter><Today /></MemoryRouter>);
    await waitFor(() => expect(screen.getByRole('heading', { name: '今日' })).toBeInTheDocument());
    expect(await screen.findByRole('heading', { name: '今やること' })).toBeInTheDocument();
    expect(screen.getByText('保育園面談', { exact: false })).toBeInTheDocument();
    expect(screen.getByText('次にやること')).toBeInTheDocument();
  });

  it('uses the RequestAttempt snapshot embedded in DailyBrief without a latest-attempt requery', async () => {
    vi.mocked(callEdgeFunction).mockClear();
    render(<MemoryRouter><Today /></MemoryRouter>);
    expect(await screen.findByText('迎えをお願い')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'やる' }));
    await waitFor(() => {
      expect(callEdgeFunction).toHaveBeenCalledWith(
        EDGE_FUNCTIONS.acceptRequest,
        expect.objectContaining({
          request_id: 'request-1',
          attempt_id: 'attempt-1',
          expected_revision: 3,
          expected_terms_revision: 2,
        }),
      );
    });
  });

  it('shows the first-priority decision card for canonical urgent actions and LINE drafts', async () => {
    render(<MemoryRouter><Today /></MemoryRouter>);
    expect(await screen.findByRole('heading', { name: '先に決めること' })).toBeInTheDocument();
    expect(screen.getByText('オムツ')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'この内容で確定' })).toBeInTheDocument();
  });
});
