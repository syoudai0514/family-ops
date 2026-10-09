import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { usePlanningData } from './usePlanningData';

const taskRows = vi.hoisted(() => ({ rows: [] as Array<Record<string, unknown>> }));

vi.mock('../../lib/supabaseClient', () => {
  const builder = (data: () => unknown) => {
    const chain: Record<string, unknown> = {};
    const result = () => Promise.resolve({ data: data(), error: null });
    for (const name of ['select', 'eq', 'lte', 'gte', 'lt', 'gt', 'neq', 'or']) chain[name] = () => chain;
    chain.order = () => result();
    return chain;
  };
  return {
    supabase: {
      from: (table: string) => builder(() => (table === 'task_instances' ? taskRows.rows : [])),
    },
  };
});

const task = (id: string, status = 'todo') => ({ id, title: id, scheduled_date: '2026-10-07', status, task_definitions: null, task_schedule_details: null });

describe('usePlanningData', () => {
  beforeEach(() => {
    taskRows.rows = [task('a'), task('b')];
  });

  it('keeps the list on screen while the same range is reloaded after a change (no jump to the top)', async () => {
    const { result } = renderHook(() => usePlanningData('hh', '2026-10-07', '2026-10-07'));
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.tasks.map((t) => t.id)).toEqual(['a', 'b']);

    taskRows.rows = [task('a', 'completed'), task('b')];
    const seen: boolean[] = [];
    let refresh: Promise<void> | undefined;
    act(() => {
      refresh = result.current.refresh();
    });
    seen.push(result.current.loading);
    await act(async () => {
      await refresh;
    });
    seen.push(result.current.loading);

    // Never "読み込み中…" for the range already shown; the new state arrives in place.
    expect(seen).toEqual([false, false]);
    expect(result.current.tasks.find((t) => t.id === 'a')?.status).toBe('completed');
  });

  it('still shows the loading state for a different range', async () => {
    const { result, rerender } = renderHook(({ s }) => usePlanningData('hh', s, s), { initialProps: { s: '2026-10-07' } });
    await waitFor(() => expect(result.current.loading).toBe(false));
    rerender({ s: '2026-10-08' });
    expect(result.current.loading).toBe(true);
    await waitFor(() => expect(result.current.loading).toBe(false));
  });
});
