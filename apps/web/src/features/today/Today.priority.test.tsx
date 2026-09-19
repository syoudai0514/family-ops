import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Today } from './Today';
import { useTodayData } from './useTodayData';
import { usePendingActions } from './usePendingActions';
import { useTodayClock } from './useTodayClock';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';

vi.mock('./useTodayData', () => ({ useTodayData: vi.fn() }));
vi.mock('./usePendingActions', () => ({ usePendingActions: vi.fn() }));
vi.mock('./useTodayClock', () => ({ useTodayClock: vi.fn() }));
vi.mock('./TodayTaskItem', () => ({ TodayTaskItem: ({ task }: { task: { title: string } }) => <li>{task.title}</li> }));
vi.mock('./TomorrowPreparationCard', () => ({ TomorrowPreparationCard: () => null }));
vi.mock('./PendingActionCard', () => ({ PendingActionCard: ({ action }: { action: { id: string } }) => <li>{action.id}</li> }));
vi.mock('./PendingActionEditModal', () => ({ PendingActionEditModal: () => null }));
vi.mock('../tasks/TaskFormModal', () => ({ TaskFormModal: () => null }));
vi.mock('../tasks/QuickAdd', () => ({ QuickAdd: () => null }));
vi.mock('../../app/AuthContext', () => ({ useAuth: () => ({ user: { id: 'user-1' } }) }));
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ household: { id: 'household-1' }, members: [], partner: null }),
}));
vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return { ...actual, callEdgeFunction: vi.fn() };
});

const task = (id: string, title: string) => ({
  id, household_id: 'household-1', task_definition_id: null, recurrence_rule_id: null,
  origin: 'manual', title, category: 'other', task_kind: 'generic_once', routine_phase: 'anytime',
  scheduled_date: '2026-09-09', due_at: null, planned_assignee_id: 'user-1', completion_mode: 'whole',
  status: 'todo', attention_state: 'active', actual_completed_by_id: null, completed_at: null,
});

const morning = task('morning-1', '朝の残り');
const evening = task('evening-1', '夜の残り');
const waiting = { ...task('waiting-1', '返事待ち'), attention_state: 'waiting' };
const urgent = { ...task('urgent-1', '担当を決める'), planned_assignee_id: null, assignment_mode: 'unassigned', revision: 4 };

function data(overrides: Record<string, unknown> = {}) {
  return {
    status: 'ready', loading: false, refreshing: false, error: null, lastUpdatedAt: Date.now(),
    urgentActions: [{ kind: 'assignment_needed', task_id: 'urgent-1', title: '担当を決める' }],
    urgentTasksById: new Map([['urgent-1', urgent]]),
    exceptions: [{ kind: 'schedule_change', event_id: 'exception-1', title: '保育園が短縮' }],
    tasks: [morning, evening],
    taskGroups: { morning: [morning], daytime: [], evening: [evening], optional: [] },
    waitingTasks: [waiting], waitingRefsByTaskId: new Map(), carryoverTasks: [], alreadyHandledTasks: [], completedTodayTasks: [],
    subtasksByTaskId: new Map(), executionTargetsByTaskId: new Map(), incomingRequests: [], requestAttemptsByRequestId: new Map(),
    unreadHandovers: [{ id: 'handover-1', period: '今日', shared_text: '水筒を玄関へ' }],
    openShoppingItems: [], briefSchedule: [],
    partnerSummary: { open_assigned: 2, completed_today: 1, critical_items: [] },
    reconciliation: { sessions: [], remaining_count: 0, actionable: false },
    tomorrowImpact: {
      local_date: '2026-09-10', task_count: 1, schedule_count: 1, carryover_count: 0, impact_count: 2,
      tasks: [{ task_id: 'tomorrow-1', title: '明日の準備' }],
      schedule: [{ kind: 'family_event', family_event_id: 'event-1', occurrence_key: null, title: '明日の予定', is_all_day: true, starts_at: null, ends_at: null, all_day_start: '2026-09-10', all_day_end_exclusive: '2026-09-11' }],
      carryovers: [],
    },
    morningSummary: { completedCount: 1, totalCount: 2 },
    refresh: vi.fn(async () => undefined),
    ...overrides,
  } as unknown as ReturnType<typeof useTodayData>;
}

const pendingBase = {
  pendingActions: [{ id: 'pending-1', normalized_payload: {}, status: 'draft' }],
  loading: false, error: null,
  confirm: vi.fn(), cancel: vi.fn(), update: vi.fn(), refresh: vi.fn(),
} as unknown as ReturnType<typeof usePendingActions>;

const mockToday = vi.mocked(useTodayData);
const mockPending = vi.mocked(usePendingActions);
const mockClock = vi.mocked(useTodayClock);
const mockCallEdgeFunction = vi.mocked(callEdgeFunction);

describe('Today first-flow priority contract', () => {
  beforeEach(() => {
    mockCallEdgeFunction.mockReset();
    mockCallEdgeFunction.mockResolvedValue({});
    mockToday.mockReturnValue(data());
    mockPending.mockReturnValue(pendingBase);
    mockClock.mockReturnValue({ now: new Date('2026-09-09T11:00:00Z'), localDate: '2026-09-09', daypart: 'evening' });
  });

  it('keeps material DailyBrief semantics in priority order without a KPI summary row', () => {
    render(<MemoryRouter><Today /></MemoryRouter>);

    // The four counter tiles (要対応 / 残り / 待ち / 明日影響) are gone on purpose.
    // In real household use three of the four read 0, so the first screenful of
    // the home screen was spent reporting that nothing was happening while the
    // one real task sat below the fold -- and a row of household KPIs is the
    // "家庭を仕事のプロジェクト管理のようにしない" line the product sets for itself.
    // The same information stays reachable as the sections asserted below.
    expect(screen.queryByRole('region', { name: '今日の重要サマリー' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /要対応 \d+件を確認/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /明日影響 \d+件を確認/ })).not.toBeInTheDocument();

    const decisionSection = screen.getByRole('region', { name: 'まず確認' });
    const exceptionSection = screen.getByRole('region', { name: 'いつもと違う' });
    const handoverSection = screen.getByRole('region', { name: '引き継ぎ・共有' });
    const morningSummary = screen.getByRole('region', { name: '朝の完了まとめ' });
    const waitingSection = screen.getByRole('region', { name: '待ち・確認' });
    const remainingHeading = screen.getByRole('heading', { name: 'まだ残っていること' });
    const tomorrowSection = screen.getByRole('region', { name: '明日に影響' });

    expect(exceptionSection).toHaveTextContent('保育園が短縮');
    expect(handoverSection).toHaveTextContent('水筒を玄関へ');
    expect(morningSummary).toHaveTextContent('朝 1/2 完了');
    expect(decisionSection.compareDocumentPosition(exceptionSection) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(exceptionSection.compareDocumentPosition(handoverSection) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(handoverSection.compareDocumentPosition(morningSummary) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(morningSummary.compareDocumentPosition(waitingSection) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(waitingSection.compareDocumentPosition(remainingHeading) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(remainingHeading.compareDocumentPosition(tomorrowSection) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  // Requirements §3 forbids 勝率/ポイント/ランキング, and design 04 §5 / §16.2 keep a
  // partner's ordinary completions in detail/history rather than pushing them as
  // scorekeeping. The card used to headline `残り N件・完了 N件` at <h2> size, which
  // on a live household morning read "残り 11件・完了 0件".
  it('keeps same-day completed work in a quiet collapsed correction section', () => {
    const completed = { ...task('done-1', '燃えるゴミのゴミ出し'), status: 'completed', completed_at: '2026-09-09T07:30:00+09:00' };
    mockToday.mockReturnValue(data({ completedTodayTasks: [completed] }));

    render(<MemoryRouter><Today /></MemoryRouter>);

    const section = screen.getByRole('region', { name: '完了済み' });
    expect(section).toHaveTextContent('完了済み（1件）');
    expect(section).not.toHaveTextContent('燃えるゴミのゴミ出し');

    fireEvent.click(screen.getByRole('button', { name: /完了済み（1件）/ }));
    expect(section).toHaveTextContent('燃えるゴミのゴミ出し');
    expect(section).toHaveTextContent('押し間違えた場合はここから未完了に戻せます');
  });

  it('shows the partner state without scoring their day', () => {
    render(<MemoryRouter><Today /></MemoryRouter>);

    const partner = screen.getByRole('region', { name: '相手の今日' });
    expect(partner).not.toHaveTextContent('完了');
    expect(partner).toHaveTextContent('担当している残り 2件');
    expect(partner.querySelector('h2')).toBeNull();
  });

  it('leads the partner card with the items that change the reader\'s own behaviour', () => {
    mockToday.mockReturnValue(data({
      partnerSummary: {
        open_assigned: 11,
        completed_today: 0,
        critical_items: [
          { task_id: 'p1', title: 'お迎え' },
          { task_id: 'p2', title: '夕食対応' },
        ],
      },
    }));
    render(<MemoryRouter><Today /></MemoryRouter>);

    const partner = screen.getByRole('region', { name: '相手の今日' });
    expect(partner).toHaveTextContent('お迎え');
    expect(partner).toHaveTextContent('夕食対応');
    expect(partner).not.toHaveTextContent('完了 0');
  });

  it('lets an unassigned Today item open a real assignment action instead of a dead end', async () => {
    mockPending.mockReturnValue({ ...pendingBase, pendingActions: [] });
    render(<MemoryRouter><Today /></MemoryRouter>);

    fireEvent.click(screen.getByRole('button', { name: '担当を決める' }));
    expect(screen.getByRole('button', { name: '自分が担当' })).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '自分が担当' }));
    await waitFor(() => expect(mockCallEdgeFunction).toHaveBeenCalledWith(
      EDGE_FUNCTIONS.changeTaskAssignment,
      {
        operation_id: expect.any(String),
        task_id: 'urgent-1',
        assignee_user_id: 'user-1',
        already_agreed: true,
        expected_revision: 4,
      },
    ));
  });

  it('does not render the Empty success surface while pending-action state is loading or failed', () => {
    mockToday.mockReturnValue(data({
      status: 'empty', urgentActions: [], exceptions: [], tasks: [],
      taskGroups: { morning: [], daytime: [], evening: [], optional: [] }, waitingTasks: [],
      unreadHandovers: [], partnerSummary: {},
      tomorrowImpact: { task_count: 0, schedule_count: 0, carryover_count: 0, impact_count: 0, tasks: [], schedule: [], carryovers: [] },
      morningSummary: { completedCount: 0, totalCount: 0 },
    }));
    mockPending.mockReturnValue({ ...pendingBase, pendingActions: [], loading: true });
    const view = render(<MemoryRouter><Today /></MemoryRouter>);
    expect(screen.queryByRole('heading', { name: '今日は確認が必要な項目はありません' })).not.toBeInTheDocument();

    mockPending.mockReturnValue({ ...pendingBase, pendingActions: [], loading: false, error: '取得失敗' });
    view.rerender(<MemoryRouter><Today /></MemoryRouter>);
    expect(screen.getByRole('alert')).toHaveTextContent('確認項目の取得に失敗しました');
    expect(screen.queryByRole('heading', { name: '今日は確認が必要な項目はありません' })).not.toBeInTheDocument();

    mockPending.mockReturnValue({ ...pendingBase, pendingActions: [], loading: false, error: null });
    view.rerender(<MemoryRouter><Today /></MemoryRouter>);
    expect(screen.getByRole('heading', { name: '今日は確認が必要な項目はありません' })).toBeInTheDocument();
  });
});
