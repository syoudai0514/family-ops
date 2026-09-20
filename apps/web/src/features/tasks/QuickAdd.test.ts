import { describe, expect, it } from 'vitest';
import { QUICK_ADD_PRIMARY_DESTINATION, quickAddDestination, quickAddOptions } from './QuickAdd';

describe('Quick Add destinations', () => {
  it('opens free input first instead of requiring a category choice', () => {
    expect(QUICK_ADD_PRIMARY_DESTINATION).toBe('/concierge');
    expect(quickAddOptions.map((option) => option.target)).not.toContain('concierge');
  });

  it('keeps the target hashes that RoutineSchedule scrolls and focuses', () => {
    expect(quickAddDestination('routine')).toBe('/settings/routines#custom-routines');
    expect(quickAddDestination('preparation')).toBe('/settings/routines#morning-preparation');
  });

  it('keeps manual fallback destinations under the secondary chooser', () => {
    expect(quickAddOptions.map((option) => option.label)).toEqual([
      '単発ToDoを追加',
      'イベント・予定を追加',
      'お願いを送る',
      '買い物を追加',
      '引き継ぎを書く',
      '画像から取り込む',
      '定例を追加',
      '朝準備を編集',
      '予定外実績を追加',
    ]);
    expect(quickAddDestination('event')).toBe('/events/new');
    expect(quickAddDestination('nursery')).toBe('/nursery/reviews');
    expect(quickAddDestination('actual')).toBe('/actuals/new');
  });
});
