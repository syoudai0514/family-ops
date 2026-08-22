import { assertEquals } from 'jsr:@std/assert@1';
import { resolveJapanesePickupDate } from './pickupDate.ts';

Deno.test('resolves today, tomorrow, and the day after tomorrow in Tokyo', () => {
  // 00:30 JST on 2026-08-22, deliberately close to the UTC date boundary.
  const now = new Date('2026-08-21T15:30:00.000Z');
  assertEquals(resolveJapanesePickupDate('今日迎えお願い', now), '2026-08-22');
  assertEquals(resolveJapanesePickupDate('明日迎えお願い', now), '2026-08-23');
  assertEquals(resolveJapanesePickupDate('明後日迎えお願い', now), '2026-08-24');
});

Deno.test('does not silently treat ambiguous weekday/date text as today', () => {
  const now = new Date('2026-08-21T15:30:00.000Z');
  assertEquals(resolveJapanesePickupDate('木曜迎えお願い', now), null);
  assertEquals(resolveJapanesePickupDate('8/25迎えお願い', now), null);
  assertEquals(resolveJapanesePickupDate('迎えお願い', now), null);
});
