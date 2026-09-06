import { describe, expect, it } from 'vitest';
import { previousIsoDate } from './CheckinPage';

describe('check-in contract helpers', () => {
  it('keeps yesterday correction on the previous calendar occurrence', () => {
    expect(previousIsoDate('2026-09-07')).toBe('2026-09-06');
    expect(previousIsoDate('2026-03-01')).toBe('2026-02-28');
  });

  it('handles year and leap-day boundaries deterministically', () => {
    expect(previousIsoDate('2026-01-01')).toBe('2025-12-31');
    expect(previousIsoDate('2024-03-01')).toBe('2024-02-29');
  });
});
