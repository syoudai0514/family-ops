/** Resolve only dates that can be safely determined without asking a follow-up. */
export function resolveJapanesePickupDate(text: string, now = new Date()): string | null {
  let offset: number | null = null;
  if (/今日/.test(text)) offset = 0;
  else if (/明後日/.test(text)) offset = 2;
  else if (/明日/.test(text)) offset = 1;

  // A weekday/date is not resolved yet. Falling back to today would silently
  // edit the wrong pickup, so it must go through needs_pwa_review instead.
  if (offset === null || /(?:月|火|水|木|金|土|日)曜|\d{1,2}\s*\/\s*\d{1,2}/.test(text)) return null;

  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Tokyo', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(now).reduce<Record<string, string>>((result, part) => {
    result[part.type] = part.value;
    return result;
  }, {});
  return new Date(Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day) + offset))
    .toISOString()
    .slice(0, 10);
}
