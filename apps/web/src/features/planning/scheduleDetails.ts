export type ScheduleDetails = {
  ends_on: string;
  location: string;
  url: string;
  notes: string;
  label_color: string;
  participants: string[];
  pinned: boolean;
  countdown: boolean;
  reminder_minutes: number | null;
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
