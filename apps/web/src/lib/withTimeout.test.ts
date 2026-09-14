import { describe, expect, it, vi } from 'vitest';
import { ClientTimeoutError, withTimeout } from './withTimeout';

describe('withTimeout', () => {
  it('returns the original result when it settles before the timeout', async () => {
    await expect(withTimeout(Promise.resolve('ok'), 50)).resolves.toBe('ok');
  });

  it('fails a hung operation instead of leaving the PWA loading forever', async () => {
    vi.useFakeTimers();
    const promise = withTimeout(new Promise<string>(() => undefined), 1_000, 'timeout');
    const assertion = expect(promise).rejects.toEqual(new ClientTimeoutError('timeout'));
    await vi.advanceTimersByTimeAsync(1_000);
    await assertion;
    vi.useRealTimers();
  });

  it('keeps the original failure', async () => {
    const error = new Error('network');
    await expect(withTimeout(Promise.reject(error), 50)).rejects.toBe(error);
  });
});
