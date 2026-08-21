import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import {
  buildAssignmentRequestFlex,
  buildAssignmentSenderPreviewFlex,
} from './lineMessageBuilders.ts';

Deno.test('assignment change Flex uses only canonical request ID in postbacks', () => {
  const message = buildAssignmentRequestFlex({
    requestId: '0d7b9b6b-9aee-4c92-802e-111111111111',
    title: '木曜のお迎え',
    message: '遅くなるのでお願いしたいです',
    scope: 'once',
  });
  assertEquals(message.type, 'flex');
  assertStringIncludes(String(message.altText), '担当変更');
  const raw = JSON.stringify(message);
  assertStringIncludes(
    raw,
    'action=accept_assignment_change&request_id=0d7b9b6b-9aee-4c92-802e-111111111111',
  );
  assertStringIncludes(
    raw,
    'action=decline_assignment_change&request_id=0d7b9b6b-9aee-4c92-802e-111111111111',
  );
});

Deno.test(
  'sender preview exposes only canonical pending action id and keeps raw text out of postback',
  () => {
    const message = buildAssignmentSenderPreviewFlex({
      pendingActionId: 'pending-1',
      title: '今日のお迎え',
      message: '迎えお願い',
      editUrl: 'https://example.test/requests?pending=pending-1',
    });
    const raw = JSON.stringify(message);
    assertStringIncludes(raw, 'この内容で送りますか？');
    assertStringIncludes(raw, 'action=confirm_pending&pending_action_id=pending-1');
    assertEquals(raw.includes('data=迎えお願い'), false);
  },
);
