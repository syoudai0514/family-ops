import { act, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useTodayClock } from './useTodayClock';

function Harness({ onRefresh }: { onRefresh: () => void | Promise<void> }) {
  const clock = useTodayClock(onRefresh);
  return <output aria-label="clock">{clock.localDate}:{clock.daypart}</output>;
}

describe('useTodayClock live refresh contract', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      value: 'visible',
    });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('keeps a long-open PWA current across 11:00, 17:00 and 00:00 JST without remounting', async () => {
    vi.setSystemTime(new Date('2026-09-09T01:59:59.500Z'));
    const refresh = vi.fn(async () => undefined);
    render(<Harness onRefresh={refresh} />);

    expect(screen.getByLabelText('clock')).toHaveTextContent('2026-09-09:morning');

    await act(async () => { await vi.advanceTimersByTimeAsync(525); });
    expect(screen.getByLabelText('clock')).toHaveTextContent('2026-09-09:day');
    expect(refresh).toHaveBeenCalledTimes(1);

    await act(async () => { await vi.advanceTimersByTimeAsync(6 * 60 * 60 * 1000); });
    expect(screen.getByLabelText('clock')).toHaveTextContent('2026-09-09:evening');
    expect(refresh).toHaveBeenCalledTimes(2);

    await act(async () => { await vi.advanceTimersByTimeAsync(7 * 60 * 60 * 1000); });
    expect(screen.getByLabelText('clock')).toHaveTextContent('2026-09-10:morning');
    expect(refresh).toHaveBeenCalledTimes(3);
  });

  it('refreshes immediately when a backgrounded PWA becomes visible again', async () => {
    vi.setSystemTime(new Date('2026-09-09T03:00:00.000Z'));
    const refresh = vi.fn(async () => undefined);
    render(<Harness onRefresh={refresh} />);

    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      value: 'hidden',
    });
    act(() => { document.dispatchEvent(new Event('visibilitychange')); });
    expect(refresh).not.toHaveBeenCalled();

    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      value: 'visible',
    });
    await act(async () => { document.dispatchEvent(new Event('visibilitychange')); });
    expect(refresh).toHaveBeenCalledTimes(1);
    expect(screen.getByLabelText('clock')).toHaveTextContent('2026-09-09:day');
  });
});
