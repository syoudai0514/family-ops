import { describe, expect, it } from 'vitest';
import { claimantAction, claimantDisclosure } from './AnyoneOwnerPage';

const base = { shopping_item_id: 'item-1', title: '牛乳', assignment_mode: 'anyone', revision: 3 };

describe('anyone owner disclosure', () => {
  it('distinguishes unclaimed, self-claimed, named-family and fail-closed states', () => {
    expect(claimantDisclosure({ ...base, active_claimant_actor_ref_id: null }, 'me')).toBe('現在: まだ誰も対応中ではありません');
    expect(claimantDisclosure({ ...base, active_claimant_actor_ref_id: 'me' }, 'me')).toBe('現在: 自分が対応中');
    expect(claimantDisclosure({
      ...base,
      active_claimant_actor_ref_id: 'partner',
      active_claimant_display_name: 'ママ',
    }, 'me')).toBe('現在: ママが対応中');
    expect(claimantDisclosure({ ...base, active_claimant_actor_ref_id: 'partner' }, 'me')).toBe('現在: 対応者を確認できません');
  });

  it('maps those states to canonical claim/release/takeover actions', () => {
    expect(claimantAction({ ...base, active_claimant_actor_ref_id: null }, 'me')).toBe('claim');
    expect(claimantAction({ ...base, active_claimant_actor_ref_id: 'me' }, 'me')).toBe('release');
    expect(claimantAction({ ...base, active_claimant_actor_ref_id: 'partner' }, 'me')).toBe('takeover');
  });
});
