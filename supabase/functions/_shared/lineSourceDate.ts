import { resolveJapaneseDate } from "./jpDate.ts";

export type GroundedLineSourceDate =
  | { kind: "unchanged"; date: string | null }
  | { kind: "grounded"; date: string }
  | { kind: "ambiguous" };

const DAY_MS = 24 * 60 * 60 * 1000;
const JST_OFFSET_MS = 9 * 60 * 60 * 1000;

function validDate(year: number, month: number, day: number): string | null {
  if (
    year < 1 || year > 9999 || month < 1 || month > 12 || day < 1 || day > 31
  ) return null;
  const iso = `${String(year).padStart(4, "0")}-${
    String(month).padStart(2, "0")
  }-${String(day).padStart(2, "0")}`;
  const date = new Date(`${iso}T00:00:00Z`);
  return Number.isFinite(date.getTime()) &&
      date.toISOString().slice(0, 10) === iso
    ? iso
    : null;
}

/**
 * A date explicitly typed by the sender outranks a model-filled draft date.
 * `now` must be the LINE event clock, so queued relative dates keep their day.
 * Never choose the first of conflicting dates or silently skip an invalid one.
 * Date-less corrections retain the existing conversation/model date.
 */
export function groundLineSourceDate(
  rawText: string,
  modelDate: string | null,
  now = new Date(),
): GroundedLineSourceDate {
  const value = rawText.normalize("NFKC");
  const candidates: Array<string | null> = [];
  const consumed: Array<[number, number]> = [];
  const add = (index: number, token: string, date: string | null) => {
    consumed.push([index, index + token.length]);
    candidates.push(date);
  };
  const overlaps = (index: number) =>
    consumed.some(([from, to]) => index >= from && index < to);
  const shifted = new Date(now.getTime() + JST_OFFSET_MS);
  const year = shifted.getUTCFullYear();
  const today = Date.UTC(year, shifted.getUTCMonth(), shifted.getUTCDate());

  // Full dates win over their embedded month/day or day-only portions.
  for (
    const match of value.matchAll(
      /(?<!\d)(?:(\d{4})\s*[年/\-]\s*)?(\d{1,2})\s*[月/\-]\s*(\d{1,2})\s*日?(?!\d)/gu,
    )
  ) {
    const index = match.index ?? 0;
    const month = Number(match[2]);
    const day = Number(match[3]);
    const relativeYear = value.slice(0, index).match(
      /(一昨年|おととし|去年|昨年|今年|来年|再来年)(?:の)?\s*$/u,
    )?.[1];
    const yearOffset = /^(?:一昨年|おととし)$/u.test(relativeYear ?? "")
      ? -2
      : /^(?:去年|昨年)$/u.test(relativeYear ?? "")
      ? -1
      : relativeYear === "来年"
      ? 1
      : relativeYear === "再来年"
      ? 2
      : 0;
    const date = match[1]
      ? relativeYear && Number(match[1]) !== year + yearOffset
        ? null
        : validDate(Number(match[1]), month, day)
      : relativeYear
      ? validDate(year + yearOffset, month, day)
      : Number.isFinite(today) && validDate(year, month, day)
      ? resolveJapaneseDate(`${month}/${day}`, now)
      : null;
    add(index, match[0], date);
  }

  for (
    const match of value.matchAll(
      /明々後日|しあさって|明後日|あさって|一昨日|おととい|明日|あした|あす|今日|きょう|今夜|今朝|昨日|きのう/gu,
    )
  ) {
    const index = match.index ?? 0;
    if (overlaps(index)) continue;
    const token = match[0];
    const days = /^(?:明々後日|しあさって)$/u.test(token)
      ? 3
      : /^(?:明後日|あさって)$/u.test(token)
      ? 2
      : /^(?:明日|あした|あす)$/u.test(token)
      ? 1
      : /^(?:一昨日|おととい)$/u.test(token)
      ? -2
      : /^(?:昨日|きのう)$/u.test(token)
      ? -1
      : 0;
    add(
      index,
      token,
      Number.isFinite(today)
        ? new Date(today + days * DAY_MS).toISOString().slice(0, 10)
        : null,
    );
  }

  for (
    const match of value.matchAll(
      /(?:再来週|来週|今週)?(?:の)?[日月火水木金土]曜(?:日)?|(?<![\d/月])\d{1,2}日(?!後|間|前|分|\d|回|中|おき)|\d{1,2}日後/gu,
    )
  ) {
    const index = match.index ?? 0;
    if (overlaps(index)) continue;
    add(
      index,
      match[0],
      Number.isFinite(today) ? resolveJapaneseDate(match[0], now) : null,
    );
  }

  if (candidates.length === 0) return { kind: "unchanged", date: modelDate };
  if (candidates.some((date) => date === null)) return { kind: "ambiguous" };
  const dates = new Set(candidates);
  if (dates.size !== 1) return { kind: "ambiguous" };
  return { kind: "grounded", date: candidates[0]! };
}
