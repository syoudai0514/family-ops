const MIN_CHECK_INTERVAL_MS = 5_000;
const UPDATE_CHECK_TIMEOUT_MS = 4_000;

interface EventTargetLike {
  addEventListener(type: string, listener: EventListenerOrEventListenerObject): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject): void;
}

interface DocumentLike extends EventTargetLike {
  visibilityState: DocumentVisibilityState;
}

interface WindowLike extends EventTargetLike {}

interface ServiceWorkerRegistrationLike {
  update(): Promise<unknown> | unknown;
}

interface ServiceWorkerContainerLike {
  getRegistration(): Promise<ServiceWorkerRegistrationLike | undefined>;
}

export interface PwaFreshnessEnvironment {
  document: DocumentLike;
  window: WindowLike;
  serviceWorker?: ServiceWorkerContainerLike;
  now: () => number;
}

function browserEnvironment(): PwaFreshnessEnvironment {
  return {
    document,
    window,
    serviceWorker:
      typeof navigator !== 'undefined' && 'serviceWorker' in navigator
        ? navigator.serviceWorker
        : undefined,
    now: () => Date.now(),
  };
}

export interface PwaReloadEnvironment {
  serviceWorker?: ServiceWorkerContainerLike;
  reload: () => void;
  setTimer: (callback: () => void, ms: number) => ReturnType<typeof setTimeout>;
  clearTimer: (timer: ReturnType<typeof setTimeout>) => void;
}

async function checkServiceWorkerUpdate(
  serviceWorker?: ServiceWorkerContainerLike,
): Promise<void> {
  const registration = await serviceWorker?.getRegistration();
  await registration?.update();
}

function browserReloadEnvironment(): PwaReloadEnvironment {
  return {
    serviceWorker:
      typeof navigator !== 'undefined' && 'serviceWorker' in navigator
        ? navigator.serviceWorker
        : undefined,
    reload: () => window.location.reload(),
    setTimer: (callback, ms) => setTimeout(callback, ms),
    clearTimer: (timer) => clearTimeout(timer),
  };
}

export async function refreshCurrentPwa(
  environment: PwaReloadEnvironment = browserReloadEnvironment(),
  updateTimeoutMs = 4_000,
): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      checkServiceWorkerUpdate(environment.serviceWorker),
      new Promise<void>((resolve) => {
        timer = environment.setTimer(resolve, updateTimeoutMs);
      }),
    ]);
  } catch {
    // A failed update check must not prevent manual recovery.
  } finally {
    if (timer) environment.clearTimer(timer);
    environment.reload();
  }
}

export function installPwaFreshnessCheck(
  environment: PwaFreshnessEnvironment = browserEnvironment(),
): () => void {
  const { document: documentRef, window: windowRef, serviceWorker, now } = environment;
  if (!serviceWorker) return () => undefined;

  let checking = false;
  let lastCheckAt = Number.NEGATIVE_INFINITY;

  const checkForUpdate = async () => {
    if (documentRef.visibilityState !== 'visible' || checking) return;

    const checkedAt = now();
    if (checkedAt - lastCheckAt < MIN_CHECK_INTERVAL_MS) return;

    checking = true;
    lastCheckAt = checkedAt;
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([
        checkServiceWorkerUpdate(serviceWorker),
        new Promise<void>((resolve) => {
          timer = setTimeout(resolve, UPDATE_CHECK_TIMEOUT_MS);
        }),
      ]);
    } catch {
      // Freshness checks must never block Today. The existing worker keeps
      // serving the current shell and the next resume/focus retries safely.
    } finally {
      if (timer) clearTimeout(timer);
      checking = false;
    }
  };

  const triggerCheck: EventListener = () => {
    void checkForUpdate();
  };

  documentRef.addEventListener('visibilitychange', triggerCheck);
  windowRef.addEventListener('pageshow', triggerCheck);
  windowRef.addEventListener('focus', triggerCheck);
  windowRef.addEventListener('online', triggerCheck);

  void checkForUpdate();

  return () => {
    documentRef.removeEventListener('visibilitychange', triggerCheck);
    windowRef.removeEventListener('pageshow', triggerCheck);
    windowRef.removeEventListener('focus', triggerCheck);
    windowRef.removeEventListener('online', triggerCheck);
  };
}
