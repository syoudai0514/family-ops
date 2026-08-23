import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import { formatScheduleReply, menuQuickReplies, readOnlyLineIntent } from './lineConversation.ts';

Deno.test('recognizes LINE schedule questions and menu without creating a mutation intent', () => {
  assertEquals(readOnlyLineIntent('今日の予定は？'), 'today');
  assertEquals(readOnlyLineIntent('明日の予定教えて'), 'tomorrow');
  assertEquals(readOnlyLineIntent('明日の予定は？'), 'tomorrow');
  assertEquals(readOnlyLineIntent('今週どうなってる？'), 'week');
  assertEquals(readOnlyLineIntent('今週の予定は？'), 'week');
  assertEquals(readOnlyLineIntent('何ができる？'), 'menu');
  assertEquals(readOnlyLineIntent('何ができるんだっけ？'), 'menu');
  assertEquals(readOnlyLineIntent('メニュー出して'), 'menu');
  assertEquals(readOnlyLineIntent('明日の保険証を準備'), null);
});

Deno.test('vague creation starters are safe menu/help intents, not fake tasks', () => {
  assertEquals(readOnlyLineIntent('明日の夜にタスクを追加したい'), 'menu');
  assertEquals(readOnlyLineIntent('タスクを登録したい'), 'menu');
  assertEquals(readOnlyLineIntent('お願いを送りたい'), 'menu');
  assertEquals(readOnlyLineIntent('買い物を追加したい'), 'menu');
});

Deno.test('menu quick replies are read-only so one tap never creates placeholder data', () => {
  const quick = menuQuickReplies();
  assertEquals(
    quick.map((item) => item.label),
    ['今日の予定', '明日の予定', '今週の予定', 'PWAを開く'],
  );
  assertEquals(
    quick
      .filter((item): item is Extract<(typeof quick)[number], { type: 'message' }> => item.type === 'message')
      .every((item) => readOnlyLineIntent(item.text) !== null),
    true,
  );
});

Deno.test('schedule reply remains compact', () => {
  const text = formatScheduleReply(
    '今日の予定',
    Array.from({ length: 9 }, (_, index) => ({
      title: `予定${index + 1}`,
      startsAt: '2026-08-23T01:30:00Z',
      roleLabel: index === 0 ? 'P' : null,
    })),
  );
  // 01:30 UTC is 10:30 in Asia/Tokyo.
  assertStringIncludes(text, '10:30 予定1 P');
  assertStringIncludes(text, 'ほか1件');
});
