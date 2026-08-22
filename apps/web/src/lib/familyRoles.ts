import type { HouseholdMember } from './types';

export type FamilyToken = 'P' | 'M' | '未';

/** Stable household role resolver. member_role is deliberately only access
 * membership (`adult`), never a presentation persona. */
export function familyToken(userId: string | null | undefined, members: HouseholdMember[]): FamilyToken {
  const role = members.find((member) => member.user_id === userId)?.family_role;
  return role === 'papa' ? 'P' : role === 'mama' ? 'M' : '未';
}

export function papaUserId(members: HouseholdMember[]) { return members.find((member) => member.family_role === 'papa')?.user_id ?? null; }
export function mamaUserId(members: HouseholdMember[]) { return members.find((member) => member.family_role === 'mama')?.user_id ?? null; }
