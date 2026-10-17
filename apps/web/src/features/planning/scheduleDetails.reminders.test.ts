import { describe, expect, it } from 'vitest';
import { defaultReminders, repeatLabel, repeatSummary } from './scheduleDetails';

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


describe('repeatLabel', () => {
  it('words each pattern from the first date', () => {
    expect(repeatLabel('weekly', '2026-10-20')).toBe('毎週火曜');
    expect(repeatLabel('biweekly', '2026-10-20')).toBe('隔週火曜');
    expect(repeatLabel('monthly', '2026-10-20')).toBe('毎月20日');
    expect(repeatLabel('monthly_nth', '2026-10-20')).toBe('毎月第3火曜');
    expect(repeatLabel('monthly_nth', '2026-10-29')).toBe('毎月最終木曜');
    expect(repeatLabel('yearly', '2026-10-20')).toBe('毎年10月20日');
    expect(repeatSummary({ repeat_frequency: 'weekdays', repeat_until: null }, '2026-10-20')).toBe('平日（月〜金）（終了日なし）');
  });
});
