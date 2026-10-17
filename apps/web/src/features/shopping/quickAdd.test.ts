import { describe, expect, it } from 'vitest';
import { shoppingTitleKey, splitShoppingInput } from './quickAdd';

describe('splitShoppingInput', () => {
  it('splits on 、 commas and new lines and drops blanks', () => {
    expect(splitShoppingInput('牛乳、卵,パン\n\n  トイレットペーパー 12ロール ')).toEqual([
      '牛乳',
      '卵',
      'パン',
      'トイレットペーパー 12ロール',
    ]);
  });

  it('keeps one copy of repeated items', () => {
    expect(splitShoppingInput('牛乳、牛乳、 牛乳 ')).toEqual(['牛乳']);
  });

  it('matches full-width and case variants as the same item', () => {
    expect(shoppingTitleKey('Ｔｉｓｓｕｅ')).toBe(shoppingTitleKey('tissue'));
  });
});
