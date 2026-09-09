import { useLayoutEffect } from 'react';
import { useLocation, useNavigationType } from 'react-router-dom';

const SCROLL_PREFIX = 'ouchi-note:scroll:';

function storageKey(locationKey: string) {
  return `${SCROLL_PREFIX}${locationKey}`;
}

export function saveScrollPosition(locationKey: string, scrollY: number) {
  if (!locationKey) return;
  try {
    sessionStorage.setItem(storageKey(locationKey), String(Math.max(0, Math.round(scrollY))));
  } catch {
    // Storage can be unavailable in private/embedded browsing. Back still works,
    // only the enhanced restoration is skipped.
  }
}

export function loadScrollPosition(locationKey: string): number | null {
  if (!locationKey) return null;
  try {
    const value = sessionStorage.getItem(storageKey(locationKey));
    if (value === null) return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
  } catch {
    return null;
  }
}

/**
 * Preserve scroll per browser-history entry. PUSH/REPLACE navigation starts a
 * new screen at the top, while browser Back and navigate(-1) both use POP and
 * return to the exact previous entry.
 */
export function NavigationStateManager() {
  const location = useLocation();
  const navigationType = useNavigationType();

  useLayoutEffect(() => {
    const currentKey = location.key;
    const targetY = navigationType === 'POP' ? loadScrollPosition(currentKey) ?? 0 : 0;
    const frame = requestAnimationFrame(() => {
      window.scrollTo({ top: targetY, left: 0, behavior: 'auto' });
    });

    return () => {
      cancelAnimationFrame(frame);
      saveScrollPosition(currentKey, window.scrollY);
    };
  }, [location.key, navigationType]);

  return null;
}
