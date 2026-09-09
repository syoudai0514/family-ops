import { describe, expect, it } from 'vitest';
import { requestBucket, responseDeadline } from './Requests';

describe('request contract semantics', () => {
  it('keeps expired requests visible instead of silently mixing them into active/history', () => {
    const now = new Date('2026-09-07T12:00:00+09:00').getTime();
    expect(requestBucket('pending', '2026-09-06T12:00:00+09:00', now)).toBe('expired');
    expect(requestBucket('consulting', '2026-09-06T12:00:00+09:00', now)).toBe('expired');
    expect(requestBucket('awaiting_confirmation', '2026-09-06T12:00:00+09:00', now)).toBe('expired');
    expect(requestBucket('pending', '2026-09-08T12:00:00+09:00', now)).toBe('active');
    expect(requestBucket('cancelled', '2026-09-08T12:00:00+09:00', now)).toBe('history');
  });

  it('keeps response deadline distinct from work deadline', () => {
    expect(responseDeadline({ id: 'a', request_id: 'r', state: 'pending', revision: 1, terms_revision: 1, terms: null, reply_due_at: '2026-09-07T09:00:00Z' })).toBe('2026-09-07T09:00:00Z');
    expect(responseDeadline(undefined)).toBeNull();
  });
});
