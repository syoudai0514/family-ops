import { describe, expect, it } from 'vitest';
import { calendarRowLabel } from './CalendarIntegrationSettings';

const row = (patch: Partial<Parameters<typeof calendarRowLabel>[0]> = {}) => ({
  active: true,
  reauth_required: false,
  is_family_write_target: false,
  ...patch,
});

// Regression: every row previously rendered the same '（接続中・読み取り対象）'
// suffix, so the calendar the app actually writes to was labelled "読み取り対象"
// exactly like the one it only reads. The radio had no visible consequence.
describe('calendar row label', () => {
  it('names the write target as the write target', () => {
    expect(calendarRowLabel(row({ is_family_write_target: true }))).toBe('（家族カレンダー・ここに書き込みます）');
  });

  it('distinguishes a read-only connection from the write target', () => {
    expect(calendarRowLabel(row())).toBe('（読み取りのみ）');
    expect(calendarRowLabel(row())).not.toBe(calendarRowLabel(row({ is_family_write_target: true })));
  });

  it('reports connection faults ahead of the write-target role', () => {
    expect(calendarRowLabel(row({ active: false, is_family_write_target: true }))).toBe('（停止中）');
    expect(calendarRowLabel(row({ reauth_required: true, is_family_write_target: true }))).toBe('（再認証が必要）');
  });
});
