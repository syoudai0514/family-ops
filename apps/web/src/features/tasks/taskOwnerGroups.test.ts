import { describe, expect, it } from 'vitest';
import { groupTasksByOwner, isPartnersTask } from './taskOwnerGroups';

const row = (id: string, extra: Record<string, unknown> = {}) => ({ id, scheduled_date: '2026-10-07', status: 'todo', outcome_reason: null, ...extra }) as never as { id: string; scheduled_date: string; status: string; outcome_reason: null };

describe('groupTasksByOwner', () => {
  it('keeps mine, shared and the other adult\'s apart', () => {
    const tasks = [
      row('mine', { planned_assignee_id: 'me' }),
      row('theirs', { planned_assignee_id: 'partner' }),
      row('anyone', { assignment_mode: 'anyone' }),
      row('unassigned', { planned_assignee_id: null }),
      row('anyone-mine', { assignment_mode: 'anyone', active_claimant_user_id: 'me' }),
      row('anyone-theirs', { assignment_mode: 'anyone', active_claimant_user_id: 'partner' }),
    ] as never[];
    const groups = groupTasksByOwner(tasks, 'me')!;
    expect(groups.mine.map((t: { id: string }) => t.id)).toEqual(['mine', 'anyone-mine']);
    expect(groups.shared.map((t: { id: string }) => t.id)).toEqual(['anyone', 'unassigned']);
    expect(groups.partner.map((t: { id: string }) => t.id)).toEqual(['theirs', 'anyone-theirs']);
  });

  it('is null (no grouping) when the viewer is unknown, and tells the other adult\'s task from the viewer\'s side', () => {
    expect(groupTasksByOwner([row('a')] as never[], null)).toBeNull();
    expect(isPartnersTask(row('t', { planned_assignee_id: 'partner' }) as never, 'me')).toBe(true);
    expect(isPartnersTask(row('t', { planned_assignee_id: 'me' }) as never, 'me')).toBe(false);
    expect(isPartnersTask(row('t', { planned_assignee_id: 'partner' }) as never, null)).toBe(false);
  });
});
