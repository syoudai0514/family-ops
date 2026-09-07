import { describe, expect, it } from 'vitest';
import { countCheckinBulkScope, previousIsoDate } from './CheckinPage';

describe('check-in contract helpers', () => {
  it('keeps yesterday correction on the previous calendar occurrence', () => {
    expect(previousIsoDate('2026-09-07')).toBe('2026-09-06');
    expect(previousIsoDate('2026-03-01')).toBe('2026-02-28');
  });

  it('handles year and leap-day boundaries deterministically', () => {
    expect(previousIsoDate('2026-01-01')).toBe('2025-12-31');
    expect(previousIsoDate('2024-03-01')).toBe('2024-02-29');
  });

  it('shows the exact final-v11 bulk scope before mutation', () => {
    expect(countCheckinBulkScope([
      { expectation: 'required' },
      { expectation: 'normal' },
      { expectation: 'optional' },
      {},
    ])).toEqual({ eligibleCount: 3, optionalCount: 1 });
  });

  it('treats legacy null/missing expectation as canonical normal, never optional', () => {
    expect(countCheckinBulkScope([{}, {}, { expectation: 'optional' }]))
      .toEqual({ eligibleCount: 2, optionalCount: 1 });
  });
});
