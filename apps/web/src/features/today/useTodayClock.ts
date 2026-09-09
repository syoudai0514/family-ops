import { useEffect, useMemo, useRef, useState } from 'react';
import { millisecondsUntilNextTodayBoundary, tokyoDaypart, tokyoLocalDate } from './todayClock';

export function useTodayClock(onRefresh: () => void | Promise<void>) {
  const [now, setNow] = useState(() => new Date());
  const refreshRef = useRef(onRefresh);

  useEffect(() => {
    refreshRef.current = onRefresh;
  }, [onRefresh]);

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null;

    const schedule = () => {
      if (timer) clearTimeout(timer);
      const current = new Date();
      timer = setTimeout(() => {
        const boundaryNow = new Date();
        setNow(boundaryNow);
        void refreshRef.current();
        schedule();
      }, millisecondsUntilNextTodayBoundary(current) + 25);
    };

    const resume = () => {
      if (document.visibilityState !== 'visible') return;
      setNow(new Date());
      void refreshRef.current();
      schedule();
    };

    schedule();
    document.addEventListener('visibilitychange', resume);
    return () => {
      if (timer) clearTimeout(timer);
      document.removeEventListener('visibilitychange', resume);
    };
  }, []);

  return useMemo(() => ({
    now,
    localDate: tokyoLocalDate(now),
    daypart: tokyoDaypart(now),
  }), [now]);
}
