import { assertEquals } from 'jsr:@std/assert@1';
import { resolveJapanesePickupDate } from './pickupDate.ts';

Deno.test('resolves today, tomorrow, and the day after tomorrow in Tokyo', () => {
  // 00:30 JST on 2026-08-22, deliberately close to the UTC date boundary.
  const now = new Date('2026-08-21T15:30:00.000Z');
  assertEquals(resolveJapanesePickupDate('今日迎えお願い', now), '2026-08-22');
  assertEquals(resolveJapanesePickupDate('明日迎えお願い', now), '2026-08-23');
  assertEquals(resolveJapanesePickupDate('明後日迎えお願い', now), '2026-08-24');
});

Deno.test('resolves explicit month/day pickup dates without AI guessing', () => {
  const now = new Date('2026-09-11T08:53:00.000Z'); // 17:53 JST
  assertEquals(resolveJapanesePickupDate('9/14のお迎えお願いできる？', now), '2026-09-14');
  assertEquals(resolveJapanesePickupDate('9月14日のお迎えお願い', now), '2026-09-14');
  assertEquals(resolveJapanesePickupDate('2026/9/14のお迎えお願い', now), '2026-09-14');
  assertEquals(resolveJapanesePickupDate('2026年9月14日のお迎えお願い', now), '2026-09-14');
});

Deno.test('month/day without a year rolls forward across the year boundary', () => {
  const now = new Date('2026-12-31T03:00:00.000Z'); // 12:00 JST
  assertEquals(resolveJapanesePickupDate('1/2のお迎えお願い', now), '2027-01-02');
});

Deno.test('keeps ambiguous or contradictory pickup dates fail-closed', () => {
  const now = new Date('2026-08-21T15:30:00.000Z');
  assertEquals(resolveJapanesePickupDate('木曜迎えお願い', now), null);
  assertEquals(resolveJapanesePickupDate('迎えお願い', now), null);
  assertEquals(resolveJapanesePickupDate('2/30迎えお願い', now), null);
  assertEquals(resolveJapanesePickupDate('今日 8/25迎えお願い', now), null);
});
