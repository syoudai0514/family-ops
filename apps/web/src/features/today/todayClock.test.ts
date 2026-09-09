import { describe, expect, it } from 'vitest';
import { millisecondsUntilNextTodayBoundary, tokyoDaypart, tokyoLocalDate } from './todayClock';

describe('todayClock', () => {
  it('changes morning to daytime at 11:00 JST', () => {
    expect(tokyoDaypart(new Date('2026-09-09T01:59:59.000Z'))).toBe('morning');
    expect(tokyoDaypart(new Date('2026-09-09T02:00:00.000Z'))).toBe('day');
    expect(millisecondsUntilNextTodayBoundary(new Date('2026-09-09T01:59:59.000Z'))).toBe(1000);
  });

  it('changes daytime to evening at 17:00 JST', () => {
    expect(tokyoDaypart(new Date('2026-09-09T07:59:59.000Z'))).toBe('day');
    expect(tokyoDaypart(new Date('2026-09-09T08:00:00.000Z'))).toBe('evening');
    expect(millisecondsUntilNextTodayBoundary(new Date('2026-09-09T07:59:59.000Z'))).toBe(1000);
  });

  it('changes the local date at 00:00 JST', () => {
    expect(tokyoLocalDate(new Date('2026-09-09T14:59:59.000Z'))).toBe('2026-09-09');
    expect(tokyoLocalDate(new Date('2026-09-09T15:00:00.000Z'))).toBe('2026-09-10');
    expect(millisecondsUntilNextTodayBoundary(new Date('2026-09-09T14:59:59.000Z'))).toBe(1000);
  });

  it('uses JST even when the runtime timezone is not JST', () => {
    expect(tokyoDaypart(new Date('2026-01-01T01:00:00.000Z'))).toBe('morning');
    expect(tokyoLocalDate(new Date('2025-12-31T16:00:00.000Z'))).toBe('2026-01-01');
  });
});
