import { describe, expect, it, vi } from 'vitest';
import {
  installPwaFreshnessCheck,
  type PwaFreshnessEnvironment,
} from './pwaFreshness';

class FakeTarget {
  private listeners = new Map<string, Set<EventListenerOrEventListenerObject>>();

  addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
    const set = this.listeners.get(type) ?? new Set<EventListenerOrEventListenerObject>();
    set.add(listener);
    this.listeners.set(type, set);
  }

  removeEventListener(type: string, listener: EventListenerOrEventListenerObject) {
    this.listeners.get(type)?.delete(listener);
  }

  dispatch(type: string) {
    for (const listener of this.listeners.get(type) ?? []) {
      if (typeof listener === 'function') listener(new Event(type));
      else listener.handleEvent(new Event(type));
    }
  }
}

function setup(visibilityState: DocumentVisibilityState = 'visible') {
  const documentTarget = new FakeTarget();
  const windowTarget = new FakeTarget();
  const update = vi.fn().mockResolvedValue(undefined);
  const getRegistration = vi.fn().mockResolvedValue({ update });
  let now = 10_000;

  const environment: PwaFreshnessEnvironment = {
    document: Object.assign(documentTarget, { visibilityState }),
    window: windowTarget,
    serviceWorker: { getRegistration },
    now: () => now,
  };

  return {
    environment,
    documentTarget,
    windowTarget,
    update,
    getRegistration,
    advance: (ms: number) => {
      now += ms;
    },
  };
}

async function flush() {
  await Promise.resolve();
  await Promise.resolve();
}

describe('installPwaFreshnessCheck', () => {
  it('checks the existing service-worker registration on a visible app start', async () => {
    const { environment, getRegistration, update } = setup();

    installPwaFreshnessCheck(environment);
    await flush();

    expect(getRegistration).toHaveBeenCalledTimes(1);
    expect(update).toHaveBeenCalledTimes(1);
  });

  it('checks for a newer app shell when a backgrounded PWA becomes visible', async () => {
    const { environment, documentTarget, getRegistration, update } = setup('hidden');

    installPwaFreshnessCheck(environment);
    await flush();
    expect(getRegistration).not.toHaveBeenCalled();

    environment.document.visibilityState = 'visible';
    documentTarget.dispatch('visibilitychange');
    await flush();

    expect(getRegistration).toHaveBeenCalledTimes(1);
    expect(update).toHaveBeenCalledTimes(1);
  });

  it('also checks on focus/pageshow but debounces duplicate resume events', async () => {
    const { environment, windowTarget, update, advance } = setup();

    installPwaFreshnessCheck(environment);
    await flush();

    windowTarget.dispatch('focus');
    windowTarget.dispatch('pageshow');
    await flush();
    expect(update).toHaveBeenCalledTimes(1);

    advance(5_001);
    windowTarget.dispatch('focus');
    await flush();
    expect(update).toHaveBeenCalledTimes(2);
  });

  it('keeps the current UI usable when the update check fails', async () => {
    const { environment, getRegistration, windowTarget, advance } = setup();
    getRegistration.mockRejectedValueOnce(new Error('offline'));

    installPwaFreshnessCheck(environment);
    await flush();

    advance(5_001);
    windowTarget.dispatch('online');
    await flush();

    expect(getRegistration).toHaveBeenCalledTimes(2);
  });

  it('is a no-op when service workers are unavailable', () => {
    const { environment, documentTarget, windowTarget } = setup();
    environment.serviceWorker = undefined;

    const cleanup = installPwaFreshnessCheck(environment);
    documentTarget.dispatch('visibilitychange');
    windowTarget.dispatch('focus');

    expect(cleanup).toBeTypeOf('function');
  });
});
