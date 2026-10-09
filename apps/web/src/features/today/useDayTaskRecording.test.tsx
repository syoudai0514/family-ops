import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { useDayTaskRecording } from './useDayTaskRecording';

const read = vi.fn();
const eq = vi.fn();
const remoteChange = vi.hoisted(() => ({ current: () => {} }));
vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: () => ({
      select: () => {
        const result = read();
        const chain = {
          eq: (...args: unknown[]) => {
            eq(...args);
            return chain;
          },
          then: result.then.bind(result),
        };
        return chain;
      },
    }),
  },
}));
vi.mock('../../lib/useRealtimeRefresh', () => ({
  useRealtimeRefresh: ({ onRemoteChange }: { onRemoteChange: () => void }) => {
    remoteChange.current = onRemoteChange;
  },
}));
const result = (date: string, status = 'completed') => ({
  data: [{ scheduled_date: date, status, outcome_reason: null }],
  error: null,
});

describe('home recording status freshness', () => {
  beforeEach(() => {
    read.mockReset();
    eq.mockReset();
  });
  it('hides the previous day immediately and ignores a late response after a quick date switch', async () => {
    let resolveFirst!: (value: ReturnType<typeof result>) => void;
    read.mockReturnValueOnce(
      new Promise((resolve) => {
        resolveFirst = resolve;
      }),
    );
    read.mockResolvedValueOnce(result('2026-10-07', 'todo'));
    const view = renderHook(({ date }) => useDayTaskRecording('hh', date), {
      initialProps: { date: '2026-10-06' },
    });
    view.rerender({ date: '2026-10-07' });
    expect(view.result.current.summary).toBeNull();
    await waitFor(() => expect(view.result.current.summary?.pending).toBe(1));
    await act(async () => {
      resolveFirst(result('2026-10-06'));
    });
    expect(view.result.current.summary?.pending).toBe(1);
    expect(eq).toHaveBeenCalledWith('household_id', 'hh');
    expect(eq).toHaveBeenCalledWith('scheduled_date', '2026-10-07');
  });
  it('updates after a partner records work, and clears success on a failed refresh', async () => {
    read.mockResolvedValueOnce(result('2026-10-06', 'todo'));
    const view = renderHook(() => useDayTaskRecording('hh', '2026-10-06'));
    await waitFor(() => expect(view.result.current.summary?.pending).toBe(1));
    read.mockResolvedValueOnce(result('2026-10-06'));
    await act(async () => {
      remoteChange.current();
    });
    await waitFor(() => expect(view.result.current.summary?.state).toBe('completed'));
    read.mockResolvedValueOnce({ data: null, error: { message: 'offline' } });
    await act(async () => {
      await view.result.current.refresh();
    });
    expect(view.result.current.summary).toBeNull();
    expect(view.result.current.error).toBe(true);
  });
});
