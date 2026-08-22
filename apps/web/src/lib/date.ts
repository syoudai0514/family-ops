// Household time is canonicalized to Asia/Tokyo. Device-local date causes
// the wrong task to appear around midnight for a travelling family member.
export function todayIsoDate(): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Tokyo', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(new Date());
  const value = (type: Intl.DateTimeFormatPartTypes) => parts.find((part) => part.type === type)?.value;
  return `${value('year')}-${value('month')}-${value('day')}`;
}

export function previousTokyoIsoDate(today = todayIsoDate()): string {
  const date = new Date(`${today}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() - 1);
  return date.toISOString().slice(0, 10);
}

export function formatDateTimeJa(iso: string | null): string {
  if (!iso) return '';
  return new Date(iso).toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' });
}

// HH:MM only, matching docs/design/v6/02_UX_AND_SCREENS.md #3's own
// Priority-1 examples ("17:30 お迎え", "18:00 ママ予定あり").
export function formatTimeJa(iso: string | null): string {
  if (!iso) return '';
  return new Date(iso).toLocaleTimeString('ja-JP', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Tokyo' });
}
