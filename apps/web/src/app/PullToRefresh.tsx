import { useEffect, useRef, useState } from 'react';

const DEFAULT_THRESHOLD = 72;
const MAX_PULL = 112;

function interactiveTarget(target: EventTarget | null) {
  return target instanceof Element
    && Boolean(target.closest('button, a, input, textarea, select, [role="dialog"], .modal-backdrop'));
}

export function PullToRefresh({
  onRefresh = () => window.location.reload(),
  threshold = DEFAULT_THRESHOLD,
}: {
  onRefresh?: () => void;
  threshold?: number;
}) {
  const startY = useRef<number | null>(null);
  const startX = useRef<number | null>(null);
  const eligible = useRef(false);
  const distanceRef = useRef(0);
  const [distance, setDistance] = useState(0);

  useEffect(() => {
    const reset = () => {
      startY.current = null;
      startX.current = null;
      eligible.current = false;
      distanceRef.current = 0;
      setDistance(0);
    };

    const onTouchStart = (event: TouchEvent) => {
      if (event.touches.length !== 1 || window.scrollY > 0 || interactiveTarget(event.target)) {
        reset();
        return;
      }
      startY.current = event.touches[0].clientY;
      startX.current = event.touches[0].clientX;
      eligible.current = true;
    };

    const onTouchMove = (event: TouchEvent) => {
      if (!eligible.current || startY.current === null || startX.current === null || event.touches.length !== 1) return;
      const dy = event.touches[0].clientY - startY.current;
      const dx = Math.abs(event.touches[0].clientX - startX.current);

      if (dy <= 0 || dx > Math.max(18, dy * 0.8) || window.scrollY > 0) {
        reset();
        return;
      }

      const pulled = Math.min(MAX_PULL, Math.round(dy * 0.62));
      distanceRef.current = pulled;
      setDistance(pulled);
      if (pulled > 8) event.preventDefault();
    };

    const onTouchEnd = () => {
      const shouldRefresh = eligible.current && distanceRef.current >= threshold;
      reset();
      if (shouldRefresh) onRefresh();
    };

    document.addEventListener('touchstart', onTouchStart, { passive: true });
    document.addEventListener('touchmove', onTouchMove, { passive: false });
    document.addEventListener('touchend', onTouchEnd, { passive: true });
    document.addEventListener('touchcancel', reset, { passive: true });

    return () => {
      document.removeEventListener('touchstart', onTouchStart);
      document.removeEventListener('touchmove', onTouchMove);
      document.removeEventListener('touchend', onTouchEnd);
      document.removeEventListener('touchcancel', reset);
    };
  }, [onRefresh, threshold]);

  if (distance <= 0) return null;

  return (
    <div
      className={distance >= threshold ? 'pull-refresh-indicator ready' : 'pull-refresh-indicator'}
      aria-live="polite"
      style={{ transform: `translate(-50%, ${Math.min(distance, 72)}px)` }}
    >
      {distance >= threshold ? '離すと更新' : '下に引いて更新'}
    </div>
  );
}
