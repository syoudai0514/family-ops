import { assertEquals } from 'jsr:@std/assert@1';
import { deterministicLineIntent } from './lineIntent.ts';

const now = new Date('2026-08-22T09:00:00Z'); // 2026-08-22 18:00 JST

Deno.test('wife dentist request becomes tomorrow-morning mama request', () => {
  const intent = deterministicLineIntent('嫁さん、明日の朝、歯医者のよやくしてほしいんだけど！', now);
  assertEquals(intent?.kind, 'request');
  assertEquals(intent?.title, '歯医者の予約');
  assertEquals(intent?.scheduledDate, '2026-08-23');
  assertEquals(intent?.daypart, 'morning');
  assertEquals(intent?.targetRole, 'mama');
});

Deno.test('tonight preparation keeps action date today, not tomorrow hospital context', () => {
  const intent = deterministicLineIntent(
    '今日の夜に明日の病院の保険証の準備しなくちゃいけないので、パパのタスクとして追加しておいて',
    now,
  );
  assertEquals(intent?.kind, 'task');
  assertEquals(intent?.title, '病院の保険証を準備');
  assertEquals(intent?.scheduledDate, '2026-08-22');
  assertEquals(intent?.daypart, 'night');
  assertEquals(intent?.targetRole, 'papa');
});

Deno.test('simple shopping remains structurally parseable', () => {
  const intent = deterministicLineIntent('明日オムツをAmazonで買って', now);
  assertEquals(intent?.kind, 'shopping');
  assertEquals(intent?.scheduledDate, '2026-08-23');
});
