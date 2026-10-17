// Push notifications for this device (schedule reminders without LINE's monthly cap).
// iPhone only allows push for the app added to the home screen (iOS 16.4+), so the
// UI explains that step instead of showing a button that cannot work.
import { callEdgeFunction } from './apiClient';
import { EDGE_FUNCTIONS } from './edgeFunctions';

export type PushAvailability =
  | 'supported'
  | 'needs-home-screen' // iPhone/iPad Safari tab: add to home screen first
  | 'unsupported';

function isIos(): boolean {
  const ua = navigator.userAgent;
  return /iPhone|iPad|iPod/.test(ua) || (ua.includes('Macintosh') && navigator.maxTouchPoints > 1);
}

function isStandalone(): boolean {
  return (
    window.matchMedia?.('(display-mode: standalone)').matches === true ||
    (navigator as Navigator & { standalone?: boolean }).standalone === true
  );
}

export function pushAvailability(): PushAvailability {
  if (typeof window === 'undefined' || !('serviceWorker' in navigator)) return 'unsupported';
  if (isIos() && !isStandalone()) return 'needs-home-screen';
  if (!('PushManager' in window) || !('Notification' in window)) return 'unsupported';
  return 'supported';
}

export function notificationPermission(): NotificationPermission | 'unsupported' {
  return typeof Notification === 'undefined' ? 'unsupported' : Notification.permission;
}

function base64UrlToBytes(value: string): Uint8Array<ArrayBuffer> {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(value.length / 4) * 4, '=');
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function deviceLabel(): string {
  const ua = navigator.userAgent;
  if (/iPhone/.test(ua)) return 'iPhone';
  if (/iPad/.test(ua) || (ua.includes('Macintosh') && navigator.maxTouchPoints > 1)) return 'iPad';
  if (/Android/.test(ua)) return 'Android';
  if (/Mac/.test(ua)) return 'Mac';
  if (/Windows/.test(ua)) return 'Windows';
  return 'ブラウザ';
}

export async function fetchPushConfig(): Promise<{ enabled: boolean; publicKey: string | null }> {
  const result = await callEdgeFunction<{ enabled: boolean; public_key: string | null }>(
    EDGE_FUNCTIONS.updateNotificationPreferences,
    { web_push_action: 'config' },
  );
  return { enabled: result.enabled, publicKey: result.public_key };
}

async function currentSubscription(): Promise<PushSubscription | null> {
  const registration = await navigator.serviceWorker.ready;
  return registration.pushManager.getSubscription();
}

async function register(subscription: PushSubscription): Promise<void> {
  const json = subscription.toJSON();
  await callEdgeFunction(EDGE_FUNCTIONS.updateNotificationPreferences, {
    web_push_action: 'subscribe',
    endpoint: json.endpoint,
    keys: json.keys,
    device_label: deviceLabel(),
  });
}

/** Must run from a tap: browsers only show the permission prompt for a user gesture. */
export async function enablePush(publicKey: string): Promise<'enabled' | 'denied'> {
  const permission = await Notification.requestPermission();
  if (permission !== 'granted') return 'denied';
  const registration = await navigator.serviceWorker.ready;
  let subscription = await registration.pushManager.getSubscription();
  const key = base64UrlToBytes(publicKey);
  const sameKey = (current: PushSubscription) => {
    const existing = current.options.applicationServerKey;
    if (!existing) return false;
    const bytes = new Uint8Array(existing);
    return bytes.length === key.length && bytes.every((value, index) => value === key[index]);
  };
  if (subscription && !sameKey(subscription)) {
    await subscription.unsubscribe();
    subscription = null;
  }
  subscription ??= await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
  await register(subscription);
  return 'enabled';
}

export async function disablePush(): Promise<void> {
  const subscription = await currentSubscription();
  if (!subscription) return;
  await callEdgeFunction(EDGE_FUNCTIONS.updateNotificationPreferences, {
    web_push_action: 'unsubscribe',
    endpoint: subscription.endpoint,
  }).catch(() => undefined);
  await subscription.unsubscribe();
}

/** Whether this device currently receives pushes for the signed-in person. */
export async function isPushEnabledHere(): Promise<boolean> {
  if (pushAvailability() !== 'supported' || notificationPermission() !== 'granted') return false;
  const subscription = await currentSubscription();
  if (!subscription) return false;
  const result = await callEdgeFunction<{ registered: boolean }>(EDGE_FUNCTIONS.updateNotificationPreferences, {
    web_push_action: 'status',
    endpoint: subscription.endpoint,
  });
  return result.registered;
}

export async function sendTestPush(): Promise<'sent' | 'retry' | 'gone' | 'dead'> {
  const subscription = await currentSubscription();
  if (!subscription) return 'gone';
  const result = await callEdgeFunction<{ outcome: 'sent' | 'retry' | 'gone' | 'dead' }>(
    EDGE_FUNCTIONS.updateNotificationPreferences,
    { web_push_action: 'test', endpoint: subscription.endpoint },
  );
  return result.outcome;
}

/**
 * Re-sends an existing subscription after sign-in, so the device follows whoever is
 * signed in and recovers if the server disabled it. Never prompts.
 */
export async function syncPushSubscription(): Promise<void> {
  if (pushAvailability() !== 'supported' || notificationPermission() !== 'granted') return;
  const subscription = await currentSubscription();
  if (subscription) await register(subscription);
}

/** Before signing out: this device should stop receiving the signed-out person's reminders. */
export async function forgetPushOnSignOut(): Promise<void> {
  if (pushAvailability() !== 'supported') return;
  try {
    await disablePush();
  } catch {
    // Signing out must not be blocked by push cleanup.
  }
}
