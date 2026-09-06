import { fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';
import { buildTodayContractSummary, TodayContractPage } from './TodayContractPage';

vi.mock('./Today', () => ({
  Today: () => <div className="task-section">today-body</div>,
  shouldShowWaitingTask: (task: { attention_state?: string | null }) => task.attention_state === 'waiting',
}));
vi.mock('./useTodayData', () => ({
  useTodayData: () => ({
    incomingRequests: [{ id: 'request-1' }],
    tasks: [
      { id: 'task-1', status: 'todo', attention_state: null },
      { id: 'task-2', status: 'in_progress', attention_state: 'waiting' },
      { id: 'task-3', status: 'completed', attention_state: null },
    ],
  }),
}));
vi.mock('./usePendingActions', () => ({
  usePendingActions: () => ({ pendingActions: [{ id: 'pending-1' }] }),
}));
vi.mock('../planning/usePlanningData', () => ({
  usePlanningData: () => ({ tasks: [{ id: 'tomorrow-task' }], occurrences: [{ id: 'tomorrow-occurrence' }] }),
}));
vi.mock('../../app/AuthContext', () => ({ useAuth: () => ({ user: { id: 'user-1' } }) }));
vi.mock('../../app/HouseholdContext', () => ({ useHousehold: () => ({ household: { id: 'household-1' } }) }));

describe('TodayContractPage', () => {
  it('builds the final-v11 four-way summary from canonical read-model inputs', () => {
    expect(buildTodayContractSummary({
      incomingRequestCount: 1,
      pendingActionCount: 2,
      tasks: [
        { status: 'todo', attention_state: null },
        { status: 'in_progress', attention_state: 'waiting' },
        { status: 'completed', attention_state: 'waiting' },
      ],
      tomorrowTaskCount: 2,
      tomorrowOccurrenceCount: 1,
    })).toEqual({ attention: 3, remaining: 2, waiting: 1, tomorrowImpact: 3 });
  });

  it('renders all four summary values and a lightweight Concierge entry', () => {
    render(
      <MemoryRouter initialEntries={['/today']}>
        <Routes>
          <Route path="/today" element={<TodayContractPage />} />
          <Route path="/concierge" element={<div>concierge-destination</div>} />
        </Routes>
      </MemoryRouter>,
    );
    expect(screen.getByRole('heading', { name: '今日の状況' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '要対応 2' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '残り 2' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '待ち 1' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '明日影響 2' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /コンシェルジュ/ }));
    expect(screen.getByText('concierge-destination')).toBeInTheDocument();
  });
});
