export function localIsoDate(date: Date): string {
  const offset = date.getTimezoneOffset() * 60_000;
  return new Date(date.getTime() - offset).toISOString().slice(0, 10);
}
export function addDays(date: Date, days: number): Date { const next = new Date(date); next.setDate(next.getDate() + days); return next; }
export function mondayOf(date: Date): Date { const next = new Date(date); const weekday = (next.getDay() + 6) % 7; next.setDate(next.getDate() - weekday); return next; }
export function formatShortDate(date: Date): string { return new Intl.DateTimeFormat('ja-JP', { weekday: 'short', month: 'numeric', day: 'numeric' }).format(date); }
