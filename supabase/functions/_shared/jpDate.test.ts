import { assertEquals } from "jsr:@std/assert@1";
import { resolveJapaneseDate } from "./jpDate.ts";

// Thursday 2026-10-15 10:00 JST.
const now = new Date("2026-10-15T01:00:00Z");

Deno.test("relative day words", () => {
  assertEquals(resolveJapaneseDate("今日の夜", now), "2026-10-15");
  assertEquals(resolveJapaneseDate("明日お迎え", now), "2026-10-16");
  assertEquals(resolveJapaneseDate("あさって歯医者", now), "2026-10-17");
  assertEquals(resolveJapaneseDate("明後日歯医者", now), "2026-10-17");
  assertEquals(resolveJapaneseDate("明々後日", now), "2026-10-18");
  assertEquals(resolveJapaneseDate("3日後に返却", now), "2026-10-18");
});

Deno.test("weekdays: bare, this week, next week", () => {
  assertEquals(resolveJapaneseDate("金曜に歯医者", now), "2026-10-16");
  assertEquals(resolveJapaneseDate("木曜", now), "2026-10-15");
  assertEquals(resolveJapaneseDate("月曜日", now), "2026-10-19");
  assertEquals(resolveJapaneseDate("来週の火曜に予防接種", now), "2026-10-20");
  assertEquals(resolveJapaneseDate("来週金曜", now), "2026-10-23");
  assertEquals(resolveJapaneseDate("再来週の月曜", now), "2026-10-26");
  assertEquals(resolveJapaneseDate("今週土曜", now), "2026-10-17");
});

Deno.test("month/day forms and year rollover", () => {
  assertEquals(resolveJapaneseDate("10/20 14時 歯医者", now), "2026-10-20");
  assertEquals(resolveJapaneseDate("11月3日の運動会", now), "2026-11-03");
  assertEquals(resolveJapaneseDate("10/14に洗濯した", now), "2026-10-14");
  assertEquals(resolveJapaneseDate("1/10 健診", now), "2027-01-10");
  assertEquals(resolveJapaneseDate("2/30", now), null);
});

Deno.test("day-of-month alone", () => {
  assertEquals(resolveJapaneseDate("20日に集金", now), "2026-10-20");
  assertEquals(resolveJapaneseDate("5日に集金", now), "2026-11-05");
  assertEquals(resolveJapaneseDate("薬を1日3回", now), null);
  assertEquals(resolveJapaneseDate("2日間", now), null);
});

Deno.test("the first written date wins and no date returns null", () => {
  assertEquals(resolveJapaneseDate("金曜の歯医者、明日準備", now), "2026-10-16");
  assertEquals(resolveJapaneseDate("明日準備して金曜の歯医者", now), "2026-10-16");
  assertEquals(resolveJapaneseDate("10/20の準備を明日", now), "2026-10-20");
  assertEquals(resolveJapaneseDate("牛乳買って", now), null);
});
