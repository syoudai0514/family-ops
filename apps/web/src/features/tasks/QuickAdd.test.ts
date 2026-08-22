import { describe, expect, it } from 'vitest';
import { quickAddDestination } from './QuickAdd';

describe('Quick Add routine destinations', () => {
  it('keeps the target hash that RoutineSchedule scrolls and focuses', () => {
    expect(quickAddDestination('routine')).toBe('/settings/routines#custom-routines');
    expect(quickAddDestination('preparation')).toBe('/settings/routines#morning-preparation');
  });
});
