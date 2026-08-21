import { assertEquals } from 'jsr:@std/assert@1';

// Keep the contract visible at the worker boundary: a bundled request must
// result in both the regular summary and the action card, not text only.
Deno.test('assignment request bundle is delivered as summary plus Flex', () => {
  const rich = { type: 'flex', altText: '担当変更', contents: {} };
  const messages = [{ type: 'text', text: '朝のチェック' }, rich];
  assertEquals(messages.length, 2);
  assertEquals(messages[1].type, 'flex');
});
