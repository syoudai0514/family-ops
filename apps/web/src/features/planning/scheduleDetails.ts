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
