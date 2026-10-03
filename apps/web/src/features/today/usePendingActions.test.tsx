import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { usePendingActions } from './usePendingActions';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import type { PendingAction } from '../../lib/types';

const call = vi.fn();

vi.mock('../../lib/apiClient', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../lib/apiClient')>(),
  callEdgeFunction: (...args: unknown[]) => call(...args),
}));

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((onResolve, onReject) => {
    resolve = onResolve;
    reject = onReject;
  });
  return { promise, resolve, reject };
}

const draft: PendingAction = {
  id: 'draft-1',
  action_type: 'task_create_once',
  normalized_payload: { title: '牛乳を買う' },
  status: 'draft',
  source: 'line',
  expires_at: '2099-01-01T00:00:00Z',
  created_at: '2026-10-01T00:00:00Z',
};

describe('usePendingActions refresh ordering', () => {
  beforeEach(() => { call.mockReset(); });

  it.each(['confirm', 'cancel'] as const)('does not restore a consumed draft from a slow read after %s', async (action) => {
    call.mockResolvedValueOnce([draft]);
    const { result } = renderHook(() => usePendingActions('household-1', 'user-1'));
    await waitFor(() => expect(result.current.pendingActions).toEqual([draft]));

    const oldRead = deferred<PendingAction[]>();
    call.mockReturnValueOnce(oldRead.promise);
    let oldRefresh!: Promise<void>;
    act(() => { oldRefresh = result.current.refresh(); });

    call.mockResolvedValueOnce({}).mockResolvedValueOnce([]);
    await act(async () => { await result.current[action](draft.id); });
    expect(call).toHaveBeenCalledWith(
      action === 'confirm' ? EDGE_FUNCTIONS.confirmPendingAction : EDGE_FUNCTIONS.cancelPendingAction,
      { pending_action_id: draft.id },
    );
    expect(result.current.pendingActions).toEqual([]);

    await act(async () => { oldRead.resolve([draft]); await oldRefresh; });
    expect(result.current.pendingActions).toEqual([]);
  });

  it('ignores an older read failure after a newer successful refresh', async () => {
    const oldRead = deferred<PendingAction[]>();
    call.mockReturnValueOnce(oldRead.promise);
    const { result } = renderHook(() => usePendingActions('household-1', 'user-1'));

    call.mockResolvedValueOnce([draft]);
    await act(async () => { await result.current.refresh(); });
    expect(result.current.pendingActions).toEqual([draft]);

    await act(async () => { oldRead.reject(new Error('old network failure')); });
    expect(result.current.error).toBeNull();
    expect(result.current.pendingActions).toEqual([draft]);
  });

  it('clears a previous identity snapshot and ignores its late response', async () => {
    call.mockResolvedValueOnce([draft]);
    const { result, rerender } = renderHook(
      ({ userId }) => usePendingActions('household-1', userId),
      { initialProps: { userId: 'user-1' } },
    );
    await waitFor(() => expect(result.current.pendingActions).toEqual([draft]));

    const oldRead = deferred<PendingAction[]>();
    call.mockReturnValueOnce(oldRead.promise);
    let oldRefresh!: Promise<void>;
    act(() => { oldRefresh = result.current.refresh(); });

    const newRead = deferred<PendingAction[]>();
    call.mockReturnValueOnce(newRead.promise);
    rerender({ userId: 'user-2' });
    expect(result.current.pendingActions).toEqual([]);
    expect(result.current.loading).toBe(true);

    await act(async () => { oldRead.resolve([draft]); await oldRefresh; });
    expect(result.current.pendingActions).toEqual([]);
    expect(result.current.loading).toBe(true);

    await act(async () => { newRead.reject(new Error('new network failure')); });
    expect(result.current.pendingActions).toEqual([]);
    expect(result.current.error).not.toBeNull();
    expect(result.current.loading).toBe(false);
  });
});
