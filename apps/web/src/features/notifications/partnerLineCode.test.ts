import { describe, expect, it } from 'vitest';
import { partnerLinkShareText } from './Notifications';

describe('partnerLinkShareText', () => {
  it('ends with the bare code so a forwarded or pasted message still links', () => {
    const code = '0123456789abcdef'.repeat(4);
    const text = partnerLinkShareText('ママ', code, '2026-11-24T12:00:00Z');
    expect(text.startsWith('おうちノートの「ママ」用のLINE連携コードです。')).toBe(true);
    expect(text).toContain('「転送」');
    expect(text.split('\n').at(-1)).toBe(code);
  });
});
