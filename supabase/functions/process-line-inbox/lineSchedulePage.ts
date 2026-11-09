import { formatScheduleDate } from "./scheduleLanguage.ts";

export interface LineScheduleRange {
  startDate: string;
  endDate: string;
  page: number;
}

export const LINE_SCHEDULE_PAGE_SIZE = 6;

/** LINE counts UTF-16 units. Never leave one half of a surrogate pair. */
export function clipScheduleText(value: string, limit: number): string {
  if (value.length <= limit) return value;
  let text = "";
  for (const char of value) {
    if (text.length + char.length > limit - 1) break;
    text += char;
  }
  return `${text}…`;
}

function validDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

/** Read-only postbacks carry absolute dates, never a relative "tomorrow". */
export function parseLineSchedulePage(fields: Record<string, string>): LineScheduleRange | null {
  if (fields.action !== "schedule_page") return null;
  const { start: startDate, end: endDate, page: pageText } = fields;
  if (!startDate || !endDate || !validDate(startDate) || !validDate(endDate)) return null;
  const days = (Date.parse(endDate) - Date.parse(startDate)) / 86_400_000;
  if (days < 0 || days > 6 || !/^\d{1,6}$/u.test(pageText ?? "")) return null;
  return { startDate, endDate, page: Number(pageText) };
}

export function schedulePageData(range: Pick<LineScheduleRange, "startDate" | "endDate">, page: number): string {
  return new URLSearchParams({
    action: "schedule_page", start: range.startDate, end: range.endDate, page: String(page),
  }).toString();
}

export function scheduleRangeTitle(startDate: string, endDate: string): string {
  return startDate === endDate
    ? `${formatScheduleDate(startDate)}の予定`
    : `${formatScheduleDate(startDate)}〜${formatScheduleDate(endDate)}の予定`;
}
