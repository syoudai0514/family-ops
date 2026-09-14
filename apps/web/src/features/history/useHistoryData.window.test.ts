import { describe, expect, it } from 'vitest';
import { windowStartDate } from './useHistoryData';

// Regression: history is a PAST-facing screen, but the query used to carry only
// a lower bound. Recurring instances are materialized months ahead, so the
// descending sort opened the screen on the furthest-future occurrence — a user
// looking at 2026-09-14 was shown 2026-12-10 first and could not reach
// yesterday without scrolling past every future row.
describe('history window', () => {
  it('starts exactly 14 days before the household day', () => {
    expect(windowStartDate('2026-09-14')).toBe('2026-08-31');
  });

  it('crosses month and year boundaries by real calendar days', () => {
    expect(windowStartDate('2026-01-07')).toBe('2025-12-24');
    expect(windowStartDate('2026-03-05')).toBe('2026-02-19');
  });

  it('is derived from the passed Tokyo date, not the device clock', () => {
    // Same call, twice, with an explicit date: no dependency on `new Date()`.
    expect(windowStartDate('2026-09-14')).toBe(windowStartDate('2026-09-14'));
  });
});
