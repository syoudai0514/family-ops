import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { TaskInstance } from '../../lib/types';
import { usePlanningData } from './usePlanningData';

const { from, withTaskActualParticipants } = vi.hoisted(() => ({
  from: vi.fn(), withTaskActualParticipants: vi.fn(),
}));
vi.mock('../../lib/supabaseClient', () => ({ supabase: { from } }));
vi.mock('../../lib/claimantUsers', () => ({ withClaimantUsers: async (_id: string, rows: unknown[]) => rows }));
vi.mock('../../lib/taskActualParticipants', () => ({ withTaskActualParticipants }));

function deferred() {
  let resolve!: () => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<void>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function query(table: string) {
  let household = 'h1';
  let date = '2026-10-12';
  const builder = {
    select: vi.fn(), eq: vi.fn(), lte: vi.fn(), or: vi.fn(), neq: vi.fn(), order: vi.fn(), lt: vi.fn(), gte: vi.fn(), gt: vi.fn(),
    then: (resolve: (value: unknown) => unknown, reject: (reason: unknown) => unknown) => Promise.resolve({
      data: table === 'task_instances' ? [{
        id: `${household}:${date}`, household_id: household, scheduled_date: date, title: date,
        status: 'completed', completion_mode: 'subtasks', actual_completed_by_id: null,
      }] : [], error: null,
    }).then(resolve, reject),
  };
  for (const method of [builder.select, builder.or, builder.neq, builder.order, builder.lt, builder.gte, builder.gt]) method.mockReturnValue(builder);
  builder.eq.mockImplementation((field: string, value: string) => { if (field === 'household_id') household = value; return builder; });
  builder.lte.mockImplementation((field: string, value: string) => { if (field === 'scheduled_date') date = value; return builder; });
  return builder;
}

describe('usePlanningData participant hydration', () => {
  beforeEach(() => {
    from.mockReset().mockImplementation(query);
    withTaskActualParticipants.mockReset();
  });

  it('keeps the selected date when an earlier participant lookup finishes later', async () => {
    const old = deferred();
    withTaskActualParticipants
      .mockImplementationOnce(async (_id: string, rows: TaskInstance[]) => { await old.promise; return rows; })
      .mockImplementation(async (_id: string, rows: TaskInstance[]) => rows.map(row => ({ ...row, actual_participant_user_ids: ['u1'] })));
    const { result, rerender } = renderHook(({ date }) => usePlanningData('h1', date, date), {
      initialProps: { date: '2026-10-12' },
    });
    await waitFor(() => expect(withTaskActualParticipants).toHaveBeenCalledTimes(1));
    rerender({ date: '2026-10-13' });
    await waitFor(() => expect(result.current.tasks[0]?.scheduled_date).toBe('2026-10-13'));
    expect(result.current.tasks[0].actual_participant_user_ids).toEqual(['u1']);
    await act(async () => { old.resolve(); await old.promise; });
    expect(result.current.tasks[0].scheduled_date).toBe('2026-10-13');
    expect(result.current.loading).toBe(false);
  });

  it('does not replace a new household result or error with an old lookup failure', async () => {
    const old = deferred();
    withTaskActualParticipants
      .mockImplementationOnce(async (_id: string, rows: TaskInstance[]) => { await old.promise; return rows; })
      .mockImplementation(async (_id: string, rows: TaskInstance[]) => rows);
    const { result, rerender } = renderHook(({ household }) => usePlanningData(household, '2026-10-13', '2026-10-13'), {
      initialProps: { household: 'h1' },
    });
    await waitFor(() => expect(withTaskActualParticipants).toHaveBeenCalledTimes(1));
    rerender({ household: 'h2' });
    await waitFor(() => expect(result.current.tasks[0]?.household_id).toBe('h2'));
    await act(async () => { old.reject(new Error('old lookup failed')); await old.promise.catch(() => undefined); });
    expect(result.current.tasks[0].household_id).toBe('h2');
    expect(result.current.error).toBeNull();
    expect(result.current.loading).toBe(false);
  });
});
