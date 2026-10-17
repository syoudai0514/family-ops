import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const callEdgeFunction = vi.fn();
vi.mock('./apiClient', () => ({ callEdgeFunction: (...args: unknown[]) => callEdgeFunction(...args) }));

import { enablePush, pushAvailability, syncPushSubscription } from './webPush';

// 65-byte uncompressed P-256 point, base64url.
const PUBLIC_KEY = 'BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

function fakeSubscription(key: Uint8Array | null, endpoint = 'https://web.push.apple.com/device') {
  return {
    endpoint,
    options: { applicationServerKey: key?.buffer ?? null },
    unsubscribe: vi.fn().mockResolvedValue(true),
    toJSON: () => ({ endpoint, keys: { p256dh: 'p', auth: 'a' } }),
  };
}

function installBrowser({
  userAgent = 'Mozilla/5.0 (Linux; Android 14)',
  standalone = false,
  existing = null as ReturnType<typeof fakeSubscription> | null,
  permission = 'granted' as NotificationPermission,
} = {}) {
  const created = fakeSubscription(null, 'https://fcm.googleapis.com/fcm/send/new');
  const pushManager = {
    getSubscription: vi.fn().mockResolvedValue(existing),
    subscribe: vi.fn().mockResolvedValue(created),
  };
  vi.stubGlobal('navigator', {
    userAgent,
    maxTouchPoints: 0,
    standalone,
    serviceWorker: { ready: Promise.resolve({ pushManager }) },
  });
  vi.stubGlobal('PushManager', function PushManager() {});
  vi.stubGlobal('Notification', { permission, requestPermission: vi.fn().mockResolvedValue(permission) });
  window.matchMedia = vi.fn().mockReturnValue({ matches: standalone }) as never;
  return { pushManager, created };
}

describe('web push', () => {
  beforeEach(() => {
    callEdgeFunction.mockReset();
    callEdgeFunction.mockResolvedValue({});
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('asks iPhone Safari users to add the app to the home screen first', () => {
    installBrowser({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)' });
    expect(pushAvailability()).toBe('needs-home-screen');
    installBrowser({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)', standalone: true });
    expect(pushAvailability()).toBe('supported');
  });

  it('subscribes with the server key and registers the device', async () => {
    const { pushManager } = installBrowser();
    expect(await enablePush(PUBLIC_KEY)).toBe('enabled');
    expect(pushManager.subscribe).toHaveBeenCalledWith(expect.objectContaining({ userVisibleOnly: true }));
    expect(callEdgeFunction).toHaveBeenCalledWith('web-push-subscription', expect.objectContaining({
      action: 'subscribe',
      endpoint: 'https://fcm.googleapis.com/fcm/send/new',
      keys: { p256dh: 'p', auth: 'a' },
      device_label: 'Android',
    }));
  });

  it('replaces a subscription made with an old server key', async () => {
    const stale = fakeSubscription(new Uint8Array(65).fill(7));
    const { pushManager } = installBrowser({ existing: stale });
    await enablePush(PUBLIC_KEY);
    expect(stale.unsubscribe).toHaveBeenCalled();
    expect(pushManager.subscribe).toHaveBeenCalled();
  });

  it('does nothing when permission is refused', async () => {
    const { pushManager } = installBrowser({ permission: 'denied' });
    expect(await enablePush(PUBLIC_KEY)).toBe('denied');
    expect(pushManager.subscribe).not.toHaveBeenCalled();
    expect(callEdgeFunction).not.toHaveBeenCalled();
  });

  it('re-registers an existing subscription on start without prompting', async () => {
    installBrowser({ existing: fakeSubscription(null) });
    await syncPushSubscription();
    expect(Notification.requestPermission).not.toHaveBeenCalled();
    expect(callEdgeFunction).toHaveBeenCalledWith('web-push-subscription', expect.objectContaining({ action: 'subscribe' }));
  });
});
