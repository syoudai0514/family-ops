import { useMemo } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../../app/AuthContext';
import { useHousehold } from '../../app/HouseholdContext';
import { addDays, tokyoIsoDate } from '../planning/dateHelpers';
import { usePlanningData } from '../planning/usePlanningData';
import { usePendingActions } from './usePendingActions';
import { useTodayData } from './useTodayData';
import { shouldShowWaitingTask, Today } from './Today';

export interface TodayContractSummary {
  attention: number;
  remaining: number;
  waiting: number;
  tomorrowImpact: number;
}

export function buildTodayContractSummary(args: {
  incomingRequestCount: number;
  pendingActionCount: number;
  tasks: Array<{ status: string; attention_state?: string | null; next_check_at?: string | null; due_at?: string | null }>;
  tomorrowTaskCount: number;
  tomorrowOccurrenceCount: number;
}): TodayContractSummary {
  const activeTasks = args.tasks.filter((task) => task.status === 'todo' || task.status === 'in_progress');
  return {
    attention: args.incomingRequestCount + args.pendingActionCount,
    remaining: activeTasks.length,
    waiting: activeTasks.filter((task) => shouldShowWaitingTask(task as never)).length,
    tomorrowImpact: args.tomorrowTaskCount + args.tomorrowOccurrenceCount,
  };
}

function jumpTo(selector: string, fallback: () => void) {
  const target = document.querySelector<HTMLElement>(selector);
  if (target) {
    target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    return;
  }
  fallback();
}

/**
 * Final-v11 first-viewport contract wrapper.
 *
 * The existing Today component remains the canonical detailed read/action surface.
 * This wrapper only adds the approved four-way operational summary and direct
 * entry to Concierge; it does not create a second task/actual/request model.
 */
export function TodayContractPage() {
  const { user } = useAuth();
  const { household } = useHousehold();
  const navigate = useNavigate();
  const today = useTodayData(household?.id ?? null, user?.id ?? null);
  const pending = usePendingActions(household?.id ?? null, user?.id ?? null);
  const tomorrowDate = useMemo(() => tokyoIsoDate(addDays(new Date(), 1)), []);
  const tomorrow = usePlanningData(household?.id ?? null, tomorrowDate, tomorrowDate);
  const summary = buildTodayContractSummary({
    incomingRequestCount: today.incomingRequests.length,
    pendingActionCount: pending.pendingActions.length,
    tasks: today.tasks,
    tomorrowTaskCount: tomorrow.tasks.length,
    tomorrowOccurrenceCount: tomorrow.occurrences.length,
  });

  return (
    <>
      <section className="app-shell today-contract-overview" aria-label="今日の状況">
        <div className="card compact-section">
          <div className="section-heading">
            <div>
              <p className="eyebrow">まずここだけ</p>
              <h2>今日の状況</h2>
            </div>
            <button
              type="button"
              className="text-button"
              onClick={() => navigate('/concierge', { state: { originPath: '/today', originScrollY: window.scrollY } })}
            >
              ✨ コンシェルジュ
            </button>
          </div>
          <div className="today-shortcuts" aria-label="今日の要点へ移動">
            <button type="button" onClick={() => jumpTo('.decision-card', () => navigate('/requests'))}>
              <strong>要対応 {summary.attention}</strong>
            </button>
            <button type="button" onClick={() => jumpTo('.next-action-hero, .task-section', () => undefined)}>
              <strong>残り {summary.remaining}</strong>
            </button>
            <button type="button" onClick={() => jumpTo('.waiting-summary', () => undefined)}>
              <strong>待ち {summary.waiting}</strong>
            </button>
            <button type="button" onClick={() => jumpTo('[aria-label="明日の予定"]', () => navigate('/week'))}>
              <strong>明日影響 {summary.tomorrowImpact}</strong>
            </button>
          </div>
          <p className="empty-hint">要対応を先に、残り・待ち・明日の影響へそのまま移動できます。</p>
        </div>
      </section>
      <Today />
    </>
  );
}
