import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { useTodayData } from './useTodayData';

const rpc = vi.fn();
const rows: Record<string, Array<Record<string, unknown>>> = {};

type QueryResult = { data: Array<Record<string, unknown>>; error: null };

function query(table: string) {
  const result: QueryResult = { data: rows[table] ?? [], error: null };
  const chain: Record<string, unknown> = {};
  for (const method of ['select', 'in', 'eq', 'order', 'is']) {
    chain[method] = vi.fn(() => chain);
  }
  chain.then = (resolve: (queryResult: QueryResult) => unknown, reject?: (reason: unknown) => unknown) =>
    Promise.resolve(result).then(resolve, reject);
  return chain;
}

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpc(...args),
    from: (table: string) => query(table),
  },
}));

vi.mock('../../lib/useRealtimeRefresh', () => ({
  useRealtimeRefresh: () => undefined,
}));

const task = {
  id: 'task-1', household_id: 'household-1', task_definition_id: null, recurrence_rule_id: null,
  origin: 'manual', title: '牛乳を買う', category: 'other', task_kind: 'generic_once', routine_phase: 'daytime',
  scheduled_date: '2026-09-09', due_at: null, planned_assignee_id: 'user-1', completion_mode: 'whole',
  status: 'todo', attention_state: 'active', actual_completed_by_id: null, completed_at: null,
};

const populatedBrief = {
  tasks: [{ task_id: 'task-1' }],
  own_task_groups: { morning: [], daytime: [{ task_id: 'task-1' }], evening: [], optional: [] },
  waiting_checks: [], carryovers: [], already_handled: [], urgent_actions: [], active_infos: [], shopping: [], schedule: [],
  partner_summary: { critical_items: [] },
  reconciliation: { sessions: [], remaining_count: 0, actionable: false },
  tomorrow_impact: { task_count: 0, schedule_count: 0, carryover_count: 0, impact_count: 0, tasks: [], schedule: [], carryovers: [] },
  morning_summary: { completed_count: 0, total_count: 0 },
};

const emptyBrief = {
  ...populatedBrief,
  tasks: [],
  own_task_groups: { morning: [], daytime: [], evening: [], optional: [] },
};

describe('useTodayData canonical snapshot states', () => {
  beforeEach(() => {
    rpc.mockReset();
    for (const key of Object.keys(rows)) delete rows[key];
    rows.task_instances = [task];
    rows.task_subtask_instances = [];
    rows.task_execution_targets = [];
    rows.requests = [];
    rows.handovers = [];
    rows.shopping_items = [];
  });

  it('transitions Loading -> Ready and keeps the last good snapshot as Stale when resync fails', async () => {
    rpc.mockResolvedValueOnce({ data: populatedBrief, error: null });
    const { result } = renderHook(() => useTodayData('household-1', 'user-1'));

    expect(result.current.status).toBe('loading');
    await waitFor(() => expect(result.current.status).toBe('ready'));
    expect(result.current.tasks.map((item) => item.id)).toEqual(['task-1']);

    rpc.mockResolvedValueOnce({ data: null, error: { message: 'network down' } });
    await act(async () => { await result.current.refresh(); });

    expect(result.current.status).toBe('stale');
    expect(result.current.error).toBe('読み込みに失敗しました。');
    expect(result.current.tasks.map((item) => item.id)).toEqual(['task-1']);
  });

  it('uses Empty only after a fresh successful canonical read and never for an initial error', async () => {
    rpc.mockResolvedValueOnce({ data: null, error: { message: 'initial read failed' } });
    const first = renderHook(() => useTodayData('household-1', 'user-1'));
    await waitFor(() => expect(first.result.current.status).toBe('error'));
    expect(first.result.current.status).not.toBe('empty');
    first.unmount();

    rpc.mockResolvedValueOnce({ data: emptyBrief, error: null });
    const second = renderHook(() => useTodayData('household-1', 'user-1'));
    await waitFor(() => expect(second.result.current.status).toBe('empty'));
    expect(second.result.current.error).toBeNull();
  });

  it('replaces a stale/ready snapshot atomically when a later successful resync returns empty', async () => {
    rpc.mockResolvedValueOnce({ data: populatedBrief, error: null });
    const { result } = renderHook(() => useTodayData('household-1', 'user-1'));
    await waitFor(() => expect(result.current.status).toBe('ready'));

    rows.task_instances = [];
    rpc.mockResolvedValueOnce({ data: emptyBrief, error: null });
    await act(async () => { await result.current.refresh(); });

    expect(result.current.status).toBe('empty');
    expect(result.current.tasks).toHaveLength(0);
    expect(result.current.taskGroups.daytime).toHaveLength(0);
    expect(result.current.lastUpdatedAt).not.toBeNull();
  });
});
