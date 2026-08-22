import { describe, expect, it } from 'vitest';
import { familyToken, mamaUserId, papaUserId } from './familyRoles';

describe('family role resolver', () => {
  const members = [
    { household_id: 'h', user_id: 'a', member_role: 'adult', family_role: 'papa' as const, joined_at: '2026-01-01' },
    { household_id: 'h', user_id: 'b', member_role: 'adult', family_role: 'mama' as const, joined_at: '2026-01-02' },
  ];
  it('uses production adult membership with stable family role', () => {
    expect(familyToken('a', members)).toBe('P'); expect(familyToken('b', members)).toBe('M');
    expect(papaUserId(members)).toBe('a'); expect(mamaUserId(members)).toBe('b');
  });
});
