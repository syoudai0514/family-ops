import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const getSessionMock = vi.fn();

vi.mock('./supabaseClient', () => ({
  supabase: { auth: { getSession: (...args: unknown[]) => getSessionMock(...args) } },
}));

describe('callEdgeFunction deadlines and outcomes', () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    vi.useFakeTimers();
    getSessionMock.mockReset();
    getSessionMock.mockResolvedValue({ data: { session: { access_token: 'test-token' } } });
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it('maps deployed edge-function names to the intended request policies', async () => {
    const { requestPolicyFor } = await import('./requestPolicy');
    expect(requestPolicyFor('list-pending-actions')).toBe('read');
    expect(requestPolicyFor('complete-task')).toBe('mutation');
    expect(requestPolicyFor('propose-ai-draft')).toBe('proposal');
  });

  it('resolves parsed JSON on 2xx', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ task_id: 'abc-123' }), { status: 200 }));
    const { callEdgeFunction } = await import('./apiClient');
    await expect(callEdgeFunction('create-task', { operation_id: 'op-1' })).resolves.toEqual({ task_id: 'abc-123' });
  });

  it('times out auth without dispatching fetch and ignores a late auth result', async () => {
    let resolveSession!: (value: unknown) => void;
    getSessionMock.mockReturnValue(new Promise((resolve) => { resolveSession = resolve; }));
    globalThis.fetch = vi.fn();
    const { callEdgeFunction } = await import('./apiClient');
    const promise = callEdgeFunction('create-task', { operation_id: 'op-1' });
    await vi.advanceTimersByTimeAsync(12_001);
    await expect(promise).rejects.toMatchObject({ code: 'AUTH_TIMEOUT', outcome: 'not_sent' });
    resolveSession({ data: { session: { access_token: 'late' } } });
    await Promise.resolve();
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it('marks a mutation fetch timeout as outcome unknown and aborts', async () => {
    globalThis.fetch = vi.fn((_url, init) => new Promise((_resolve, reject) => {
      (init?.signal as AbortSignal)?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
    })) as typeof fetch;
    const { callEdgeFunction } = await import('./apiClient');
    const promise = callEdgeFunction('send-request', { operation_id: 'op-1' });
    await vi.advanceTimersByTimeAsync(30_001);
    await expect(promise).rejects.toMatchObject({ code: 'RESULT_UNKNOWN', outcome: 'unknown' });
  });

  it('marks a mutation body timeout as unknown', async () => {
    const response = { ok: true, status: 200, text: () => new Promise<string>(() => {}) } as Response;
    globalThis.fetch = vi.fn().mockResolvedValue(response);
    const { callEdgeFunction } = await import('./apiClient');
    const promise = callEdgeFunction('send-request', { operation_id: 'op-1' });
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(30_001);
    await expect(promise).rejects.toMatchObject({ code: 'RESULT_UNKNOWN', outcome: 'unknown' });
  });

  it('treats malformed 2xx mutation JSON as unknown', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(new Response('not-json', { status: 200 }));
    const { callEdgeFunction } = await import('./apiClient');
    await expect(callEdgeFunction('send-request', { operation_id: 'op-1' })).rejects.toMatchObject({ outcome: 'unknown' });
  });

  it('keeps typed 4xx as rejected', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ error: { code: 'TASK_TERMINAL', message: 'done' } }), { status: 409 }));
    const { callEdgeFunction } = await import('./apiClient');
    await expect(callEdgeFunction('complete-task', { operation_id: 'op-1' })).rejects.toMatchObject({ code: 'TASK_TERMINAL', outcome: 'rejected', status: 409 });
  });

  it('uses shorter read deadline and no unknown mutation wording for reads', async () => {
    globalThis.fetch = vi.fn(() => new Promise<Response>(() => {}));
    const { callEdgeFunction } = await import('./apiClient');
    const promise = callEdgeFunction('get-week-schedule', {});
    await vi.advanceTimersByTimeAsync(12_001);
    await expect(promise).rejects.toMatchObject({ code: 'NETWORK_ERROR', outcome: 'not_sent' });
  });
});
