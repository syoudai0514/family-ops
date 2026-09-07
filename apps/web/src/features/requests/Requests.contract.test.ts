import { describe, expect, it } from 'vitest';

export type RequestBucketsInput = {
  status: string;
  recipient_id: string | null;
  requester_id: string | null;
  due_at?: string | null;
};

export function requestBucket(status: string, dueAt: string | null | undefined, nowMs = Date.now()): 'active' | 'expired' | 'history' {
  if (['completed', 'cancelled', 'declined'].includes(status)) return 'history';
  if (dueAt && new Date(dueAt).getTime() < nowMs) return 'expired';
  return 'active';
}

describe('request bucket semantics', () => {
  it('keeps expired requests visible instead of silently mixing them into active/history', () => {
    const now = new Date('2026-09-07T12:00:00+09:00').getTime();
    expect(requestBucket('pending', '2026-09-06T12:00:00+09:00', now)).toBe('expired');
    expect(requestBucket('pending', '2026-09-08T12:00:00+09:00', now)).toBe('active');
    expect(requestBucket('cancelled', '2026-09-08T12:00:00+09:00', now)).toBe('history');
  });
});
