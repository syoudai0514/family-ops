import { describe, expect, it } from 'vitest';
import { quickAddDestination, quickAddOptions } from './QuickAdd';

describe('Quick Add destinations', () => {
  it('keeps the target hashes that RoutineSchedule scrolls and focuses', () => {
    expect(quickAddDestination('routine')).toBe('/settings/routines#custom-routines');
    expect(quickAddDestination('preparation')).toBe('/settings/routines#morning-preparation');
  });

  it('routes Event planning and Nursery review to their human review surfaces', () => {
    expect(quickAddDestination('event')).toBe('/events/new');
    expect(quickAddDestination('nursery')).toBe('/nursery/reviews');
  });

  it('puts the approved Concierge first and keeps unplanned actual as a dedicated path', () => {
    expect(quickAddOptions.map((option) => option.label)).toEqual([
      '✨ おうちコンシェルジュ',
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
    expect(quickAddDestination('concierge')).toBe('/concierge');
    expect(quickAddDestination('actual')).toBe('/actuals/new');
  });
});
