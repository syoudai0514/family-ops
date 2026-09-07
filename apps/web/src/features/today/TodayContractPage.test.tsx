import { fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';
import { buildTodayContractSummary, TodayContractPage } from './TodayContractPage';

vi.mock('./Today', () => ({
  Today: () => <div>today-body</div>,
  shouldShowWaitingTask: (task: { attention_state?: string | null }) => task.attention_state === 'waiting',
}));
vi.mock('./TodayTaskItem', () => ({
  TodayTaskItem: ({ task }: { task: { title: string } }) => <li>{task.title}</li>,
}));
vi.mock('../tasks/TaskFormModal', () => ({ TaskFormModal: () => null }));
vi.mock('../checkin/useCurrentRoutineSessions', () => ({
  useCurrentRoutineSessions: () => ({
    sessions: [{ id: 'session-1', can_act: true, session_type: 'pickup', remaining_count: 2 }],
    error: null,
  }),
}));
vi.mock('./useTodayData', () => ({
  useTodayData: () => ({
    incomingRequests: [{ id: 'request-1', shared_title: 'お迎えの返事', due_at: null }],
    tasks: [
      { id: 'task-1', title: '洗濯', status: 'todo', planned_assignee_id: 'user-1', attention_state: null, routine_phase: 'evening' },
      { id: 'task-2', title: '写真館へ確認電話', status: 'in_progress', planned_assignee_id: 'user-1', attention_state: 'waiting', routine_phase: 'anytime' },
      { id: 'task-3', title: '水着セット', status: 'completed', planned_assignee_id: 'user-1', actual_completed_by_id: 'user-2', attention_state: null, routine_phase: 'anytime' },
      { id: 'task-4', title: '明日の水着準備', status: 'todo', planned_assignee_id: null, attention_state: null, routine_phase: 'anytime' },
    ],
    carryoverTasks: [],
    subtasksByTaskId: new Map(),
    refresh: vi.fn(),
  }),
}));
vi.mock('./usePendingActions', () => ({
  usePendingActions: () => ({
    pendingActions: [{ id: 'pending-1', normalized_payload: { title: '確認待ちのお願い' } }],
  }),
}));
vi.mock('../planning/usePlanningData', () => ({
  usePlanningData: () => ({
    tasks: [{ id: 'tomorrow-task', title: '明日の着替え準備' }],
    occurrences: [{ id: 'tomorrow-occurrence', title: '保育園' }],
  }),
}));
vi.mock('../../app/AuthContext', () => ({ useAuth: () => ({ user: { id: 'user-1' } }) }));
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({
    household: { id: 'household-1' },
    members: [
      { user_id: 'user-1', family_role: 'papa', profile: { display_name: 'パパ' } },
      { user_id: 'user-2', family_role: 'mama', profile: { display_name: 'ママ' } },
    ],
    partner: { user_id: 'user-2' },
  }),
}));

describe('TodayContractPage', () => {
  it('builds the final-v11 four-way summary from canonical read-model inputs', () => {
    expect(buildTodayContractSummary({
      incomingRequestCount: 1,
      pendingActionCount: 2,
      currentUserId: 'user-1',
      tasks: [
        { status: 'todo', planned_assignee_id: 'user-1', attention_state: null },
        { status: 'in_progress', planned_assignee_id: 'user-1', attention_state: 'waiting' },
        { status: 'todo', planned_assignee_id: null, attention_state: null },
        { status: 'completed', planned_assignee_id: 'user-1', attention_state: 'waiting' },
      ],
      tomorrowTaskCount: 2,
      tomorrowOccurrenceCount: 1,
    })).toEqual({ attention: 4, remaining: 1, waiting: 1, tomorrowImpact: 3 });
  });

  it('renders summary plus the material final-v11 Today sections and actual task names', () => {
    render(
      <MemoryRouter initialEntries={['/today']}>
        <Routes>
          <Route path="/today" element={<TodayContractPage />} />
          <Route path="/concierge" element={<div>concierge-destination</div>} />
        </Routes>
      </MemoryRouter>,
    );

    expect(screen.getByText('最初にここだけ見ればOK')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: '今日の状況' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /返事・担当未定.*要対応 3/ })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /今日の自分タスク.*残り 1/ })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /待ち・あとで確認.*待ち 1/ })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /明日の予定・準備.*明日影響 2/ })).toBeInTheDocument();

    expect(screen.getByRole('heading', { name: '放置すると困ること' })).toBeInTheDocument();
    expect(screen.getByText('お迎えの返事')).toBeInTheDocument();
    expect(screen.getByText('明日の水着準備')).toBeInTheDocument();
    expect(screen.getByText('洗濯')).toBeInTheDocument();
    expect(screen.getByText('写真館へ確認電話')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: '明日の予定・準備' })).toBeInTheDocument();
    expect(screen.getByText('明日の着替え準備')).toBeInTheDocument();
    expect(screen.getByText(/水着セット は相手が対応済み/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '2件をまとめて入力' })).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /コンシェルジュ/ }));
    expect(screen.getByText('concierge-destination')).toBeInTheDocument();
  });
});
