import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import {
  buildAssignmentRequestFlex,
  buildAssignmentSenderPreviewFlex,
  buildPendingActionPreviewFlex,
  rewritePickupRequest,
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

Deno.test('natural pickup request is rewritten into a gentle shared message', () => {
  assertEquals(
    rewritePickupRequest('今日ちょっと遅くなるから迎えお願い'),
    '今日は少し遅くなりそうです。お迎えをお願いしてもいい？',
  );
});

Deno.test('natural-language sender preview supports in-LINE edit before confirmation', () => {
  const raw = JSON.stringify(
    buildPendingActionPreviewFlex({
      pendingActionId: 'pending-2',
      kindLabel: 'タスク',
      title: '病院の保険証を準備',
      scheduleLabel: '8/22 夜',
      targetLabel: 'パパ',
    }),
  );
  assertStringIncludes(raw, 'action=edit_pending&pending_action_id=pending-2');
  assertStringIncludes(raw, 'action=confirm_pending&pending_action_id=pending-2');
  assertEquals(raw.includes('病院の保険証を準備'), true);
});

Deno.test(
  'all confirmation actions use the compact footer so iPhone LINE can show every button',
  () => {
    const message = buildPendingActionPreviewFlex({
      pendingActionId: 'pending-compact',
      kindLabel: 'タスク',
      title: '歯医者の予約',
      scheduleLabel: '明日 朝',
      targetLabel: 'ママ',
    }) as {
      contents: {
        footer: {
          paddingAll: string;
          contents: Array<{ height: string; action: { label: string } }>;
        };
      };
    };
    assertEquals(message.contents.footer.paddingAll, '12px');
    assertEquals(
      message.contents.footer.contents.map((button) => button.height),
      ['sm', 'sm', 'sm'],
    );
    assertEquals(
      message.contents.footer.contents.map((button) => button.action.label),
      ['この内容で登録', '編集', 'キャンセル'],
    );
  },
);

Deno.test(
  'structured sender preview keeps appointment context and checklist visible before confirmation',
  () => {
    const raw = JSON.stringify(
      buildPendingActionPreviewFlex({
        pendingActionId: 'pending-3',
        kindLabel: 'タスク',
        title: '皮膚科の準備',
        scheduleLabel: '8/23 10:00',
        targetLabel: '自分',
        detailLines: ['予定: 藤沢の皮膚科 11:00', '準備: ・子供の身支度 ・診察カード ・保険証'],
      }),
    );
    assertStringIncludes(raw, '皮膚科の準備');
    assertStringIncludes(raw, '予定: 藤沢の皮膚科 11:00');
    assertStringIncludes(raw, '準備: ・子供の身支度 ・診察カード ・保険証');
  },
);
