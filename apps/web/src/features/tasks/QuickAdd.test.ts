import { describe, expect, it } from 'vitest';
import { quickAddDestination, quickAddOptions } from './QuickAdd';

describe('Quick Add destinations', () => {
  it('keeps the target hashes that RoutineSchedule scrolls and focuses', () => {
    expect(quickAddDestination('routine')).toBe('/settings/routines#custom-routines');
    expect(quickAddDestination('preparation')).toBe('/settings/routines#morning-preparation');
  });

  it('routes Event planning to the human review surface', () => {
    expect(quickAddDestination('event')).toBe('/events/new');
  });

  it('keeps every Quick Add action in the single shared sheet', () => {
    expect(quickAddOptions.map((option) => option.label)).toEqual([
      '単発ToDoを追加',
      'イベント・予定を追加',
      'お願いを送る',
      '買い物を追加',
      '引き継ぎを書く',
      '定例を追加',
      '朝準備を編集',
    ]);
  });
});
