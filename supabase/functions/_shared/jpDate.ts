// Japanese date words as families type them into LINE: 明日 / あさって / 金曜 /
// 来週の火曜 / 10/20 / 10月20日 / 20日. Used by the deterministic fallbacks so that
// "金曜に歯医者" is not silently registered for today when the AI is unavailable.

const JST_OFFSET_MS = 9 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;
const WEEKDAYS = "日月火水木金土";

function jstToday(now: Date): Date {
  const shifted = new Date(now.getTime() + JST_OFFSET_MS);
  return new Date(Date.UTC(shifted.getUTCFullYear(), shifted.getUTCMonth(), shifted.getUTCDate()));
}

function iso(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function validDate(year: number, month: number, day: number): Date | null {
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day
    ? date
    : null;
}

type Candidate = { index: number; date: Date };

/**
 * Returns the first date written in `text` (YYYY-MM-DD, Asia/Tokyo), or null when
 * the text names no date. A month/day far in the past means next year ("1/10" in
 * December); a recent past date is kept so "10/14にやった" still records 10/14.
 */
export function resolveJapaneseDate(text: string, now = new Date()): string | null {
  const value = text.normalize("NFKC");
  const today = jstToday(now);
  const candidates: Candidate[] = [];
  const add = (index: number, date: Date | null) => {
    if (date) candidates.push({ index, date });
  };
  const plusDays = (days: number) => new Date(today.getTime() + days * DAY_MS);

  for (const match of value.matchAll(/(?:(\d{4})[年/])?(\d{1,2})[月/](\d{1,2})日?/gu)) {
    const month = Number(match[2]);
    const day = Number(match[3]);
    let date = validDate(Number(match[1] ?? today.getUTCFullYear()), month, day);
    if (date && !match[1] && today.getTime() - date.getTime() > 180 * DAY_MS) {
      date = validDate(today.getUTCFullYear() + 1, month, day);
    }
    add(match.index ?? 0, date);
  }

  // "20日" alone: this month, or next month once it has passed. Skip "3日後" and month/day forms.
  for (const match of value.matchAll(/(?<![\d/月])(\d{1,2})日(?!後|間|前|分|\d|回|中|おき)/gu)) {
    const day = Number(match[1]);
    let date = validDate(today.getUTCFullYear(), today.getUTCMonth() + 1, day);
    if (date && date.getTime() < today.getTime()) {
      const next = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth() + 1, 1));
      date = validDate(next.getUTCFullYear(), next.getUTCMonth() + 1, day);
    }
    add(match.index ?? 0, date);
  }

  for (const match of value.matchAll(/(\d{1,2})日後/gu)) {
    add(match.index ?? 0, plusDays(Number(match[1])));
  }

  const relative: Array<[RegExp, number]> = [
    [/明々後日|しあさって/gu, 3],
    [/明後日|あさって/gu, 2],
    [/明日|あした|あす/gu, 1],
    [/今日|今夜|今朝|きょう/gu, 0],
  ];
  const taken: Array<[number, number]> = [];
  for (const [pattern, days] of relative) {
    for (const match of value.matchAll(pattern)) {
      const start = match.index ?? 0;
      // The longer word wins: "明後日" is not also "明日", "明々後日" not "明後日".
      if (taken.some(([from, to]) => start >= from && start < to)) continue;
      taken.push([start, start + match[0].length]);
      add(start, plusDays(days));
    }
  }

  for (const match of value.matchAll(/(再来週|来週|今週)?(?:の)?([日月火水木金土])曜/gu)) {
    const target = WEEKDAYS.indexOf(match[2]);
    const todayIndex = today.getUTCDay();
    let days: number;
    if (match[1]) {
      // Weeks start on Monday: 来週の月曜 is the Monday after this week's.
      const mondayOffset = -((todayIndex + 6) % 7);
      const weeks = match[1] === "再来週" ? 2 : match[1] === "来週" ? 1 : 0;
      days = mondayOffset + weeks * 7 + ((target + 6) % 7);
    } else {
      days = (target - todayIndex + 7) % 7;
    }
    add(match.index ?? 0, plusDays(days));
  }

  if (candidates.length === 0) return null;
  candidates.sort((a, b) => a.index - b.index);
  return iso(candidates[0].date);
}
