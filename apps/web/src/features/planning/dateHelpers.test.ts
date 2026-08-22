import { describe, expect, it } from 'vitest';
import { tokyoIsoDate } from './dateHelpers';

describe('tokyoIsoDate', () => {
  it('places a UTC timestamp after midnight in Japan on the next date', () => {
    expect(tokyoIsoDate('2026-08-21T15:30:00Z')).toBe('2026-08-22');
  });

  it('keeps an all-day ISO date at midnight JST on the same date', () => {
    expect(tokyoIsoDate('2026-08-22T00:00:00+09:00')).toBe('2026-08-22');
  });
});
