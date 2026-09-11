function tokyoDateParts(now: Date): { year: number; month: number; day: number; iso: string } {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Tokyo',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(now).reduce<Record<string, string>>((result, part) => {
    result[part.type] = part.value;
    return result;
  }, {});
  const year = Number(parts.year);
  const month = Number(parts.month);
  const day = Number(parts.day);
  return { year, month, day, iso: `${parts.year}-${parts.month}-${parts.day}` };
}

function validIsoDate(year: number, month: number, day: number): string | null {
  if (!Number.isInteger(year) || !Number.isInteger(month) || !Number.isInteger(day)) return null;
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31) return null;
  const candidate = new Date(Date.UTC(year, month - 1, day));
  if (
    candidate.getUTCFullYear() !== year ||
    candidate.getUTCMonth() !== month - 1 ||
    candidate.getUTCDate() !== day
  ) return null;
  return candidate.toISOString().slice(0, 10);
}

function explicitPickupDate(text: string, now: Date): string | null {
  const normalized = text.normalize('NFKC');
  const current = tokyoDateParts(now);

  const slashWithYear = normalized.match(/(?:^|[^\d])(\d{4})\s*\/\s*(\d{1,2})\s*\/\s*(\d{1,2})(?:[^\d]|$)/u);
  if (slashWithYear) {
    return validIsoDate(Number(slashWithYear[1]), Number(slashWithYear[2]), Number(slashWithYear[3]));
  }

  const japaneseWithYear = normalized.match(/(?:^|[^\d])(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日?(?:[^\d]|$)/u);
  if (japaneseWithYear) {
    return validIsoDate(Number(japaneseWithYear[1]), Number(japaneseWithYear[2]), Number(japaneseWithYear[3]));
  }

  const slashMonthDay = normalized.match(/(?:^|[^\d])(\d{1,2})\s*\/\s*(\d{1,2})(?:[^\d]|$)/u);
  const japaneseMonthDay = normalized.match(/(?:^|[^\d])(\d{1,2})\s*月\s*(\d{1,2})\s*日?(?:[^\d]|$)/u);
  const match = slashMonthDay ?? japaneseMonthDay;
  if (!match) return null;

  const month = Number(match[1]);
  const day = Number(match[2]);
  let candidate = validIsoDate(current.year, month, day);
  if (!candidate) return null;
  if (candidate < current.iso) candidate = validIsoDate(current.year + 1, month, day);
  return candidate;
}

/** Resolve only dates that can be safely determined without asking a follow-up. */
export function resolveJapanesePickupDate(text: string, now = new Date()): string | null {
  const normalized = text.normalize('NFKC');
  const current = tokyoDateParts(now);

  let relative: string | null = null;
  let offset: number | null = null;
  if (/今日/u.test(normalized)) offset = 0;
  else if (/明後日/u.test(normalized)) offset = 2;
  else if (/明日/u.test(normalized)) offset = 1;

  if (offset !== null) {
    relative = new Date(Date.UTC(current.year, current.month - 1, current.day + offset))
      .toISOString()
      .slice(0, 10);
  }

  const explicit = explicitPickupDate(normalized, now);
  if (relative && explicit) return relative === explicit ? relative : null;
  if (explicit) return explicit;
  if (relative) return relative;

  // A weekday-only or date-less request is still ambiguous. Do not silently
  // choose an occurrence; let the caller ask only for the missing date.
  return null;
}
