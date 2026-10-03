// @vitest-environment node
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { describe, expect, it, vi } from 'vitest';

describe('service worker activation', () => {
  it('purges the unsafe legacy cache before reloading windows, without blocking activation on navigation', async () => {
    let activate!: (event: { waitUntil: (promise: Promise<unknown>) => void }) => void;
    let finishPurge!: (result: boolean) => void;
    const purge = vi.fn(
      () =>
        new Promise<boolean>((resolve) => {
          finishPurge = resolve;
        }),
    );
    // A claimed page can wait for activation before its navigation completes.
    const navigate = vi.fn(() => new Promise<never>(() => {}));
    runInNewContext(readFileSync(new URL('../public/sw-update.js', import.meta.url), 'utf8'), {
      caches: { delete: purge },
      self: {
        addEventListener: (_event: string, callback: typeof activate) => {
          activate = callback;
        },
        clients: { matchAll: async () => [{ url: 'https://app.example/today', navigate }] },
      },
    });
    let activation!: Promise<unknown>;
    activate({
      waitUntil: (promise) => {
        activation = promise;
      },
    });
    expect(purge).toHaveBeenCalledExactlyOnceWith('supabase-rest-reads');
    expect(navigate).not.toHaveBeenCalled();
    finishPurge(true);
    const completed = await Promise.race([
      activation.then(() => true),
      new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 50)),
    ]);
    expect(completed).toBe(true);
    expect(navigate).toHaveBeenCalledExactlyOnceWith('https://app.example/today');
  });
});
