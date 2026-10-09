import { describe, expect, it } from 'vitest';
import { dayHasTransportToClear } from './dayTransport';
import type { PlanningTask } from './calendarProjection';

const t = (extra: Record<string, unknown>) => ({ id: 'x', scheduled_date: '2026-10-12', status: 'todo', origin: 'recurring', definition_code: 'dropoff', ...extra }) as unknown as PlanningTask;

describe('dayHasTransportToClear', () => {
  it('is true while an open recurring dropoff, pickup or Codmon task is on the day', () => {
    expect(dayHasTransportToClear([t({})], '2026-10-12')).toBe(true);
    expect(dayHasTransportToClear([t({ definition_code: 'pickup' })], '2026-10-12')).toBe(true);
    expect(dayHasTransportToClear([t({ definition_code: 'codmon_submit' })], '2026-10-12')).toBe(true);
  });

  it('is false once they are done or cancelled, for other days, and for tasks made by hand', () => {
    expect(dayHasTransportToClear([t({ status: 'completed' })], '2026-10-12')).toBe(false);
    expect(dayHasTransportToClear([t({ status: 'cancelled' })], '2026-10-12')).toBe(false);
    expect(dayHasTransportToClear([t({})], '2026-10-13')).toBe(false);
    expect(dayHasTransportToClear([t({ origin: 'manual' })], '2026-10-12')).toBe(false);
    expect(dayHasTransportToClear([t({ definition_code: 'laundry' })], '2026-10-12')).toBe(false);
  });
});
