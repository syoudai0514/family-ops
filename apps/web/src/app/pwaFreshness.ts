const MIN_CHECK_INTERVAL_MS = 5_000;

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
    try {
      const registration = await serviceWorker.getRegistration();
      await registration?.update();
    } catch {
      // Freshness checks must never block Today. The existing worker keeps
      // serving the current shell and the next resume/focus retries safely.
    } finally {
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
