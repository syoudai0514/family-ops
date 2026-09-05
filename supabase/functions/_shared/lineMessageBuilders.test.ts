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
    assertStringIncludes(raw, 'お願いの確認');
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
  assertStringIncludes(raw, 'タスクの確認');
  assertStringIncludes(raw, '日時');
  assertStringIncludes(raw, '8/22 夜');
  assertStringIncludes(raw, '担当');
  assertStringIncludes(raw, 'パパ');
  assertStringIncludes(raw, 'action=edit_pending&pending_action_id=pending-2');
  assertStringIncludes(raw, 'action=confirm_pending&pending_action_id=pending-2');
  assertEquals(raw.includes('病院の保険証を準備'), true);
  assertEquals(raw.includes('この内容でいいですか？'), false);
});

Deno.test(
  'three confirmation actions fit in two compact footer rows on iPhone LINE',
  () => {
    const message = buildPendingActionPreviewFlex({
      pendingActionId: 'pending-compact',
      kindLabel: 'タスク',
      title: '歯医者の予約',
      scheduleLabel: '明日 朝',
      targetLabel: 'ママ',
    }) as {
      contents: {
        body: { paddingAll: string; spacing: string };
        footer: {
          paddingAll: string;
          spacing: string;
          contents: Array<
            | { type: 'button'; height: string; action: { label: string } }
            | {
                type: 'box';
                layout: string;
                contents: Array<{ type: 'button'; height: string; action: { label: string } }>;
              }
          >;
        };
      };
    };

    assertEquals(message.contents.body.paddingAll, '12px');
    assertEquals(message.contents.body.spacing, 'xs');
    const footer = message.contents.footer;
    assertEquals(footer.paddingAll, '6px');
    assertEquals(footer.spacing, 'xs');
    assertEquals(footer.contents.length, 2);
    assertEquals(footer.contents[0].type, 'button');
    assertEquals((footer.contents[0] as { action: { label: string } }).action.label, 'この内容で登録');

    const secondaryRow = footer.contents[1] as {
      type: 'box';
      layout: string;
      contents: Array<{ height: string; action: { label: string } }>;
    };
    assertEquals(secondaryRow.type, 'box');
    assertEquals(secondaryRow.layout, 'horizontal');
    assertEquals(secondaryRow.contents.map((button) => button.height), ['sm', 'sm']);
    assertEquals(secondaryRow.contents.map((button) => button.action.label), ['編集', 'キャンセル']);
  },
);

Deno.test('request Flex keeps the primary pair compact and adds a PWA other-response path', () => {
  const message = buildAssignmentRequestFlex({
    requestId: 'request-compact',
    title: '今日のお迎え',
    message: 'お願いできますか？',
    scope: 'once',
    otherResponseUrl: 'https://example.test/requests?request=request-compact&response=other',
  }) as {
    contents: {
      footer: {
        contents: Array<
          | { type: 'button'; action: { label: string } }
          | { type: 'box'; layout: string; contents: Array<{ action: { label: string } }> }
        >;
      };
    };
  };
  const row = message.contents.footer.contents[0];
  assertEquals((row as { action: { label: string } }).action.label, 'やる');
  const secondaryRow = message.contents.footer.contents[1];
  assertEquals((secondaryRow as { layout: string }).layout, 'horizontal');
  assertEquals((secondaryRow as { contents: Array<{ action: { label: string } }> }).contents.map((button) => button.action.label), ['難しい', 'その他の返答']);
});

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
