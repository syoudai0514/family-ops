import { assertEquals } from 'jsr:@std/assert@1';
import { childButtons, matchChild } from './nurseryChildReply.ts';

const children = [
  { id: '1', name: '詩乃', aliases: ['しの', 'ウタノ'] },
  { id: '2', name: '将生', aliases: ['しょうせい'] },
];
Deno.test('child name replies resolve only a unique context', () => {
  for (const value of ['詩乃', '詩乃のです！', 'しののやつ', 'ウタノの保育園からの依頼！']) {
    assertEquals(matchChild(value, children)?.id, '1');
  }
  assertEquals(matchChild('詩乃の歯医者を登録して', children), null);
  assertEquals(matchChild('詩乃', [...children, { id: '3', name: '詩乃', aliases: [] }]), null);
  assertEquals(childButtons({ id: 'photo', revision: 2, contexts: children }).map((action) => action.label), ['詩乃', '将生']);
});
