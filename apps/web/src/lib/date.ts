// Local (browser-clock) date in YYYY-MM-DD form, matching the
// `scheduled_date`/`occurred_on` column format used across the read model.
// Household timezone lives on `households.timezone`, but WP2's screens all
// operate on "today" from the perspective of whoever is holding the phone,
// so the browser's own local date is the right source of truth here.
export function todayIsoDate(): string {
  const now = new Date();
  const yyyy = now.getFullYear();
  const mm = String(now.getMonth() + 1).padStart(2, '0');
  const dd = String(now.getDate()).padStart(2, '0');
  return `${yyyy}-${mm}-${dd}`;
}

export function formatDateTimeJa(iso: string | null): string {
  if (!iso) return '';
  return new Date(iso).toLocaleString('ja-JP');
}

// HH:MM only, matching docs/design/v6/02_UX_AND_SCREENS.md #3's own
// Priority-1 examples ("17:30 お迎え", "18:00 ママ予定あり").
export function formatTimeJa(iso: string | null): string {
  if (!iso) return '';
  return new Date(iso).toLocaleTimeString('ja-JP', { hour: '2-digit', minute: '2-digit' });
}
