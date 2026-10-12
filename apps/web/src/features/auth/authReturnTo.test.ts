import { describe, expect, it, vi } from 'vitest';
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

  it.each(['/\\evil.test', '/\t/evil.test', '/\n/evil.test', '/\r/evil.test'])(
    'rejects browser-normalized external destinations: %j',
    (value) => expect(safeReturnTo(value)).toBeNull(),
  );

  it('rejects normalized callback paths and retains valid invite query strings', () => {
    expect(safeReturnTo('/tasks/../auth/callback?code=secret')).toBeNull();
    expect(safeReturnTo('/join?token=invite%2Ftoken#confirm')).toBe(
      '/join?token=invite%2Ftoken#confirm',
    );
  });

  it('keeps sign-in usable when private browsing denies session storage', () => {
    const write = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new DOMException('Storage denied', 'SecurityError');
    });
    const read = vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new DOMException('Storage denied', 'SecurityError');
    });
    const remove = vi.spyOn(Storage.prototype, 'removeItem').mockImplementation(() => {
      throw new DOMException('Storage denied', 'SecurityError');
    });
    try {
      expect(() => rememberAuthReturnTo('/join?token=invite-token')).not.toThrow();
      expect(consumeAuthReturnTo()).toBe('/join?token=invite-token');
      expect(consumeAuthReturnTo()).toBeNull();
    } finally {
      write.mockRestore();
      read.mockRestore();
      remove.mockRestore();
    }
  });
});
