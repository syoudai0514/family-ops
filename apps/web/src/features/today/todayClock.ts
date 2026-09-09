export type TodayDaypart = 'morning' | 'day' | 'evening';

const JST_OFFSET_MS = 9 * 60 * 60 * 1000;

function shiftedJst(date: Date): Date {
  return new Date(date.getTime() + JST_OFFSET_MS);
}

export function tokyoLocalDate(date: Date): string {
  const shifted = shiftedJst(date);
  const year = shifted.getUTCFullYear();
  const month = String(shifted.getUTCMonth() + 1).padStart(2, '0');
  const day = String(shifted.getUTCDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

export function tokyoDaypart(date: Date): TodayDaypart {
  const hour = shiftedJst(date).getUTCHours();
  if (hour < 11) return 'morning';
  if (hour < 17) return 'day';
  return 'evening';
}

export function millisecondsUntilNextTodayBoundary(date: Date): number {
  const shifted = shiftedJst(date);
  const hour = shifted.getUTCHours();
  const boundaryHour = hour < 11 ? 11 : hour < 17 ? 17 : 24;
  const currentMs =
    ((hour * 60 + shifted.getUTCMinutes()) * 60 + shifted.getUTCSeconds()) * 1000 +
    shifted.getUTCMilliseconds();
  const boundaryMs = boundaryHour * 60 * 60 * 1000;
  return Math.max(1, boundaryMs - currentMs);
}

export function formatTokyoHeading(date: Date): string {
  return new Intl.DateTimeFormat('ja-JP', {
    timeZone: 'Asia/Tokyo',
    weekday: 'long',
    month: 'long',
    day: 'numeric',
  }).format(date);
}
