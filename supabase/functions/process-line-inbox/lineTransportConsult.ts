import type { LineQuickReplyAction } from '../_shared/lineMessaging.ts';

function dateOffset(date: string, days: number): string | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;
  const parsed = new Date(`${date}T00:00:00Z`);
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== date) return null;
  parsed.setUTCDate(parsed.getUTCDate() + days);
  return parsed.toISOString().slice(0, 10);
}

/** Choice data contains a concrete day, never a relative date resolved later. */
export function transportConsultChoices(today: string): LineQuickReplyAction[] {
  const tomorrow = dateOffset(today, 1);
  if (!tomorrow) return [];
  return [
    { label: '今日の送り', date: today, code: 'dropoff' },
    { label: '今日のお迎え', date: today, code: 'pickup' },
    { label: '明日の送り', date: tomorrow, code: 'dropoff' },
    { label: '明日のお迎え', date: tomorrow, code: 'pickup' },
  ].map(({ label, date, code }) => ({ type: 'postback', label, displayText: label,
    data: new URLSearchParams({ action: 'transport_consult_choose', date, code }).toString() }));
}

export function validTransportConsultChoice(fields: Record<string, string>, today: string): boolean {
  const tomorrow = dateOffset(today, 1);
  return tomorrow !== null && (fields.date === today || fields.date === tomorrow) &&
    (fields.code === 'dropoff' || fields.code === 'pickup');
}
