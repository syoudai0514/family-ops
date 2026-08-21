import { describe, expect, it } from 'vitest';
import { consumeAuthReturnTo, rememberAuthReturnTo, safeReturnTo } from './authReturnTo';

describe('auth return-to deep links', () => {
  it('keeps a join token through auth and consumes it once', () => {
    rememberAuthReturnTo('/join?token=invite-token');
    expect(consumeAuthReturnTo()).toBe('/join?token=invite-token');
    expect(consumeAuthReturnTo()).toBeNull();
  });

  it('rejects external and callback redirect targets', () => {
    expect(safeReturnTo('https://evil.example')).toBeNull();
    expect(safeReturnTo('//evil.example')).toBeNull();
    expect(safeReturnTo('/auth/callback?x=1')).toBeNull();
    expect(safeReturnTo('/checkin/session-1')).toBe('/checkin/session-1');
  });
});
