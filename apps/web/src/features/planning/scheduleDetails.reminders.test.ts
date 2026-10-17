import { describe, expect, it } from 'vitest';
import { defaultReminders } from './scheduleDetails';

describe('defaultReminders', () => {
  it('uses the household setting when present', () => {
    const household = { default_timed_reminders: [1440, 30], default_all_day_reminders: [] };
    expect(defaultReminders(true, household)).toEqual([30, 1440]);
    expect(defaultReminders(false, household)).toEqual([]);
  });

  it('falls back to 1時間前 / 前日 夜8時', () => {
    expect(defaultReminders(true, null)).toEqual([60]);
    expect(defaultReminders(false, {})).toEqual([780]);
  });
});
