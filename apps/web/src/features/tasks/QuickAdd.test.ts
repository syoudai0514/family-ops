import { describe, expect, it } from 'vitest';
import { quickAddDestination, quickAddOptions } from './QuickAdd';

describe('Quick Add routine destinations', () => {
  it('keeps the target hash that RoutineSchedule scrolls and focuses', () => {
    expect(quickAddDestination('routine')).toBe('/settings/routines#custom-routines');
    expect(quickAddDestination('preparation')).toBe('/settings/routines#morning-preparation');
  });

  it('keeps every Quick Add action in the single shared sheet', () => {
    expect(quickAddOptions.map((option) => option.label)).toEqual([
      '単発予定を追加',
      'お願いを送る',
      '買い物を追加',
      '引き継ぎを書く',
      '定例を追加',
      '朝準備を編集',
    ]);
  });
});
