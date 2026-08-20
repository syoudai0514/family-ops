import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const getSessionMock = vi.fn();

vi.mock('./supabaseClient', () => ({
  supabase: {
    auth: {
      getSession: (...args: unknown[]) => getSessionMock(...args),
    },
  },
}));

describe('callEdgeFunction', () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    getSessionMock.mockReset();
    getSessionMock.mockResolvedValue({ data: { session: { access_token: 'test-token' } } });
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
    vi.restoreAllMocks();
  });

  it('resolves with the parsed JSON body on a 2xx response', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ task_id: 'abc-123' }), { status: 200 }),
    );

    const { callEdgeFunction } = await import('./apiClient');
    const result = await callEdgeFunction<{ task_id: string }>('create-task', { operation_id: 'op-1' });

    expect(result).toEqual({ task_id: 'abc-123' });
    expect(globalThis.fetch).toHaveBeenCalledWith(
      'http://localhost:54321/functions/v1/create-task',
      expect.objectContaining({
        method: 'POST',
        headers: expect.objectContaining({
          authorization: 'Bearer test-token',
          apikey: 'test-publishable-key',
        }),
      }),
    );
  });

  it('throws a FamilyOpsApiError with code/message/status/detail parsed from the error envelope', async () => {
    // A fresh Response per call — Response bodies can only be read once, and
    // callEdgeFunction is invoked twice below.
    globalThis.fetch = vi.fn().mockImplementation(
      () =>
        new Response(
          JSON.stringify({
            error: { code: 'TASK_TERMINAL', message: 'Task already completed.', detail: { taskId: 'x' } },
          }),
          { status: 409 },
        ),
    );

    const { callEdgeFunction, FamilyOpsApiError } = await import('./apiClient');

    await expect(callEdgeFunction('complete-task', { operation_id: 'op-1' })).rejects.toMatchObject({
      name: 'FamilyOpsApiError',
      code: 'TASK_TERMINAL',
      message: 'Task already completed.',
      status: 409,
      detail: { taskId: 'x' },
    });
    await expect(callEdgeFunction('complete-task', { operation_id: 'op-1' })).rejects.toBeInstanceOf(
      FamilyOpsApiError,
    );
  });

  it('falls back to an UNKNOWN_ERROR code when the error body is not the expected envelope shape', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(new Response('internal server error', { status: 500 }));

    const { callEdgeFunction } = await import('./apiClient');

    await expect(callEdgeFunction('create-task', { operation_id: 'op-1' })).rejects.toMatchObject({
      code: 'UNKNOWN_ERROR',
      status: 500,
    });
  });

  it('throws NOT_AUTHENTICATED without calling fetch when there is no active session', async () => {
    getSessionMock.mockResolvedValue({ data: { session: null } });
    globalThis.fetch = vi.fn();

    const { callEdgeFunction } = await import('./apiClient');

    await expect(callEdgeFunction('create-task', { operation_id: 'op-1' })).rejects.toMatchObject({
      code: 'NOT_AUTHENTICATED',
    });
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it('throws NETWORK_ERROR when fetch itself rejects', async () => {
    globalThis.fetch = vi.fn().mockRejectedValue(new TypeError('Failed to fetch'));

    const { callEdgeFunction } = await import('./apiClient');

    await expect(callEdgeFunction('create-task', { operation_id: 'op-1' })).rejects.toMatchObject({
      code: 'NETWORK_ERROR',
    });
  });
});
