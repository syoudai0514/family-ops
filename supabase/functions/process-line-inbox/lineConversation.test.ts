import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import { formatScheduleReply, menuQuickReplies, readOnlyLineIntent } from './lineConversation.ts';

Deno.test('recognizes LINE schedule questions and menu without creating a mutation intent', () => {
  assertEquals(readOnlyLineIntent('今日の予定は？'), 'today');
  assertEquals(readOnlyLineIntent('明日の予定教えて'), 'tomorrow');
  assertEquals(readOnlyLineIntent('明日の予定は？'), 'tomorrow');
  assertEquals(readOnlyLineIntent('今週どうなってる？'), 'week');
  assertEquals(readOnlyLineIntent('今週の予定は？'), 'week');
  assertEquals(readOnlyLineIntent('何ができる？'), 'menu');
  assertEquals(readOnlyLineIntent('明日の保険証を準備'), null);
});

Deno.test('menu has one-tap schedule shortcuts and schedule reply remains compact', () => {
  assertEquals(
    menuQuickReplies()
      .slice(0, 3)
      .map((item) => item.label),
    ['今日の予定', '明日の予定', '今週の予定'],
  );
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
