import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Today } from './Today';
import type { PlanningTask } from '../planning/calendarProjection';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';

const state = vi.hoisted(() => ({
  papa: '10000000-0000-4000-8000-000000000001',
  mama: '10000000-0000-4000-8000-000000000002',
  taskId: '20000000-0000-4000-8000-000000000001',
  householdId: '30000000-0000-4000-8000-000000000001',
  authenticatedUserId: '10000000-0000-4000-8000-000000000001',
  tasks: [] as PlanningTask[],
  members: [] as HouseholdMemberWithProfile[],
  call: vi.fn(),
  refresh: vi.fn(async () => {}),
}));

vi.mock('../../lib/apiClient', async () => ({
  ...await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient'),
  callEdgeFunction: (...args: unknown[]) => state.call(...args),
}));
vi.mock('../../app/AuthContext', () => ({ useAuth: () => ({ user: { id: state.authenticatedUserId } }) }));
vi.mock('../../app/HouseholdContext', () => ({ useHousehold: () => ({
  household: { id: state.householdId }, members: state.members,
  me: state.members.find((member) => member.user_id === state.papa),
  partner: state.members.find((member) => member.user_id === state.mama),
}) }));
vi.mock('../planning/usePlanningData', () => ({ usePlanningData: () => ({
  tasks: state.tasks, occurrences: [], loading: false, error: null, refresh: state.refresh,
}) }));
vi.mock('./useTodayClock', () => ({ useTodayClock: () => ({
  now: new Date('2026-10-14T03:00:00Z'), localDate: '2026-10-14', daypart: 'morning',
}) }));
vi.mock('./useDayTaskRecording', () => ({ useDayTaskRecording: () => ({
  summary: null, error: null, refresh: state.refresh,
}) }));

function entry(date = '2026-10-15', overrides: Record<string, string> = {}) {
  const params = new URLSearchParams({
    date, for: state.papa, assignment_task: state.taskId, assignment_to: state.papa, ...overrides,
  });
  return `/today?${params}`;
}

function renderEntry(url = entry()) {
  return render(<MemoryRouter initialEntries={[url]}><Today /></MemoryRouter>);
}

function task(date = '2026-10-15'): PlanningTask {
  return {
    id: state.taskId, household_id: state.householdId, task_definition_id: null,
    recurrence_rule_id: null, origin: 'recurring', title: '送り', category: 'dropoff',
    routine_phase: 'morning', scheduled_date: date, due_at: `${date}T08:00:00+09:00`,
    planned_assignee_id: state.mama, assignment_mode: 'person', task_kind: 'transport',
    completion_mode: 'whole', status: 'todo', actual_completed_by_id: null,
    completed_at: null, revision: 7,
  };
}

describe('LINE navigation opens the actual transport assignment without implying consent', () => {
  beforeEach(() => {
    sessionStorage.clear();
    state.call.mockReset().mockResolvedValue({ ok: true });
    state.refresh.mockClear();
    state.authenticatedUserId = state.papa;
    state.members = [
      { household_id: state.householdId, user_id: state.papa, member_role: 'adult', family_role: 'papa', joined_at: '2026-01-01', profile: null },
      { household_id: state.householdId, user_id: state.mama, member_role: 'adult', family_role: 'mama', joined_at: '2026-01-01', profile: null },
    ];
    state.tasks = [task()];
  });

  it.each(['2026-10-14', '2026-10-15'])('opens the real row on %s, preselects the requested parent and sends nothing on navigation', (date) => {
    state.tasks = [task(date)];
    renderEntry(entry(date));
    expect(screen.getByText('担当をどう変える？')).toBeVisible();
    expect(screen.getByRole('combobox', { name: '担当する人' })).toHaveValue(state.papa);
    expect(screen.getByRole('radio', { name: /まだ合意していない/ })).toBeChecked();
    expect(screen.getByRole('radio', { name: /すでに話し合い済み/ })).not.toBeChecked();
    expect(state.call).not.toHaveBeenCalled();
  });

  it('blocks a request to oneself, including a forged submit, until the user explicitly confirms prior agreement', async () => {
    renderEntry();
    expect(screen.getByRole('button', { name: 'お願いを送る' })).toBeDisabled();
    expect(screen.getByText(/自分宛てのお願いは送れません/)).toBeVisible();
    fireEvent.submit(screen.getByText('担当をどう変える？').closest('form')!);
    expect(state.call).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('radio', { name: /すでに話し合い済み/ }));
    fireEvent.click(screen.getByRole('button', { name: '担当を変更' }));
    await waitFor(() => expect(state.call).toHaveBeenCalledTimes(1));
    expect(state.call).toHaveBeenCalledWith('change-task-assignment', expect.objectContaining({
      task_id: state.taskId, assignee_user_id: state.papa, already_agreed: true, expected_revision: 7,
    }));
    expect(state.call).not.toHaveBeenCalledWith('create-assignment-change-request', expect.anything());
  });

  it('keeps the existing request flow from the current owner to the other parent', async () => {
    state.tasks = [{ ...task(), planned_assignee_id: state.papa }];
    renderEntry(entry('2026-10-15', { assignment_to: state.mama }));
    expect(screen.getByRole('button', { name: 'お願いを送る' })).toBeEnabled();
    expect(state.call).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'お願いを送る' }));
    await waitFor(() => expect(state.call).toHaveBeenCalledWith('create-assignment-change-request', expect.objectContaining({
      task_id: state.taskId, recipient_user_id: state.mama, scope: 'once', expected_task_revision: 7,
    })));
  });

  it.each([
    ['別の受信者', { for: '10000000-0000-4000-8000-000000000099' }],
    ['家族以外の希望担当', { assignment_to: '10000000-0000-4000-8000-000000000099' }],
    ['無効な作業ID', { assignment_task: 'invalid' }],
    ['異なる日付', { date: '2026-10-16' }],
  ])('does not auto-open or mutate for %s', (_label, overrides) => {
    renderEntry(entry('2026-10-15', overrides));
    expect(screen.queryByText('担当をどう変える？')).not.toBeInTheDocument();
    expect(state.call).not.toHaveBeenCalled();
  });

  it.each(['completed', 'skipped', 'cancelled'] as const)('ignores a %s occurrence', (status) => {
    state.tasks = [{ ...task(), status }];
    renderEntry();
    expect(screen.queryByText('担当をどう変える？')).not.toBeInTheDocument();
    expect(state.call).not.toHaveBeenCalled();
  });

  it('ignores a task from another household even if it is accidentally present in the loaded rows', () => {
    state.tasks = [{ ...task(), household_id: '30000000-0000-4000-8000-000000000099' }];
    renderEntry();
    expect(screen.queryByText('担当をどう変える？')).not.toBeInTheDocument();
    expect(state.call).not.toHaveBeenCalled();
  });

  it('does not treat a member of another household as an eligible target', () => {
    state.members[1] = { ...state.members[1], household_id: '30000000-0000-4000-8000-000000000099' };
    renderEntry(entry('2026-10-15', { assignment_to: state.mama }));
    expect(screen.queryByText('担当をどう変える？')).not.toBeInTheDocument();
    expect(state.call).not.toHaveBeenCalled();
  });

  it('ignores a stale household identity after switching the authenticated account', () => {
    state.authenticatedUserId = state.mama;
    renderEntry();
    expect(screen.queryByText('担当をどう変える？')).not.toBeInTheDocument();
    expect(state.call).not.toHaveBeenCalled();
  });
});
