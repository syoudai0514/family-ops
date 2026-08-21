import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import { buildAssignmentRequestFlex } from './lineMessageBuilders.ts';

Deno.test('assignment change Flex uses only canonical request ID in postbacks', () => {
  const message = buildAssignmentRequestFlex({ requestId: '0d7b9b6b-9aee-4c92-802e-111111111111', title: '木曜のお迎え', message: '遅くなるのでお願いしたいです', scope: 'once' });
  assertEquals(message.type, 'flex');
  assertStringIncludes(String(message.altText), '担当変更');
  const raw = JSON.stringify(message);
  assertStringIncludes(raw, 'action=accept_assignment_change&request_id=0d7b9b6b-9aee-4c92-802e-111111111111');
  assertStringIncludes(raw, 'action=decline_assignment_change&request_id=0d7b9b6b-9aee-4c92-802e-111111111111');
});
