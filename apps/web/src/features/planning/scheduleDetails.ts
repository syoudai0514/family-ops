export type ScheduleDetails = {
  ends_on: string;
  location: string;
  url: string;
  notes: string;
  label_color: string;
  participants: string[];
  pinned: boolean;
  countdown: boolean;
  /** Legacy single reminder; `reminders` wins when present. */
  reminder_minutes: number | null;
  /** Minutes before the start (all-day: before 09:00). null = not chosen yet, use the default. */
  reminders?: number[] | null;
  repeat_frequency: 'none' | 'daily' | 'weekly' | 'monthly';
  repeat_until: string | null;
  checklist: string[];
  checked_items?: number[];
};

export function emptyScheduleDetails(date: string): ScheduleDetails {
  return {
    ends_on: date,
    location: '',
    url: '',
    notes: '',
    label_color: '#28b78d',
    participants: [],
    pinned: false,
    countdown: false,
    reminder_minutes: null,
    reminders: null,
    repeat_frequency: 'none',
    repeat_until: null,
    checklist: [],
  };
}

/** PostgREST can expose the composite foreign-key relation as a one-row array. */
export function readScheduleDetails(value: unknown, date: string): ScheduleDetails | null {
  const relation = Array.isArray(value) ? value[0] : value;
  if (!relation || typeof relation !== 'object' || !('details' in relation)) return null;
  const details = relation.details;
  if (!details || typeof details !== 'object' || Array.isArray(details)) return null;
  return { ...emptyScheduleDetails(date), ...details } as ScheduleDetails;
}

// Mirrors public.default_schedule_reminders(): LINE and AI入力 use the same default.
export function defaultReminders(hasStartTime: boolean): number[] {
  return hasStartTime ? [60] : [780];
}

export function reminderOffsets(details: ScheduleDetails): number[] {
  if (Array.isArray(details.reminders)) return [...details.reminders].sort((a, b) => a - b);
  return details.reminder_minutes === null || details.reminder_minutes === undefined
    ? []
    : [details.reminder_minutes];
}

export const MAX_REMINDERS = 5;
export const TIMED_REMINDER_OPTIONS = [0, 5, 10, 15, 30, 60, 120, 1440, 2880, 10080];
export const ALL_DAY_REMINDER_OPTIONS = [0, 780, 1440, 2880, 10080];

export function reminderLabel(minutes: number, allDay: boolean): string {
  if (allDay) {
    const allDayLabels: Record<number, string> = {
      0: '当日 朝9時',
      780: '前日 夜8時',
      1440: '前日 朝9時',
      2880: '2日前 朝9時',
      10080: '1週間前 朝9時',
    };
    if (allDayLabels[minutes]) return allDayLabels[minutes];
  }
  if (minutes === 0) return '開始時';
  if (minutes % 10080 === 0) return `${minutes / 10080}週間前`;
  if (minutes % 1440 === 0) return minutes === 1440 ? '前日' : `${minutes / 1440}日前`;
  if (minutes % 60 === 0) return `${minutes / 60}時間前`;
  return `${minutes}分前`;
}

export const SCHEDULE_ATTACHMENT_BUCKET = 'schedule-attachments';
export const SCHEDULE_FILE_MAX_BYTES = 10 * 1024 * 1024;
export const SCHEDULE_FILE_TYPES = [
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/heic',
  'image/heif',
  'application/pdf',
  'text/plain',
];

export function validateScheduleFiles(files: File[]): string | null {
  if (files.length > 10) return '添付は一度に10件まで選んでください。';
  for (const file of files) {
    if (file.size > SCHEDULE_FILE_MAX_BYTES) return `${file.name}は10MBを超えています。`;
    if (!SCHEDULE_FILE_TYPES.includes(file.type))
      return `${file.name}は対応していません。画像・PDF・テキストを選んでください。`;
  }
  return null;
}
