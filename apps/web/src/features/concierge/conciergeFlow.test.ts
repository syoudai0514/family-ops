import { describe, expect, it } from 'vitest';
import { normalizeConciergeProposal } from './conciergeFlow';
import { commitConciergeCandidate } from './conciergeCommit';

const member = (userId: string, role: string) => ({
  household_id: '00000000-0000-4000-8000-000000000001', user_id: userId,
  member_role: 'adult' as const, family_role: role, joined_at: '2026-01-01T00:00:00Z', profile: null,
});

describe('Concierge canonical flow', () => {
  it('normalizes the shared LINE semantic candidate shape before rendering', () => {
    const proposal = normalizeConciergeProposal({
      read_only_intent: null, clarification: null,
      candidates: [{ id: 'c1', kind: 'task', title: '水着を準備', scheduledDate: '2026-09-08', missingFields: [] }],
    }, '明日の水着を準備');
    expect(proposal.candidates[0]).toMatchObject({
      candidateId: 'c1', kind: 'task', title: '水着を準備', sourceText: '明日の水着を準備',
      intent: { scheduledDate: '2026-09-08' },
    });
  });

  it('uses create-task only after confirmation for a task candidate', async () => {
    const calls: Array<{ name: string; body: object }> = [];
    const result = await commitConciergeCandidate({
      candidateId: 'task-1', kind: 'task', title: '水着を準備', sourceText: '水着を準備', missingFields: [], intent: { scheduledDate: '2026-09-08' },
    }, {
      members: [], me: null, partner: null, timeZone: 'Asia/Tokyo',
      operationId: () => '00000000-0000-4000-8000-000000000123',
      invoke: async (name, body) => { calls.push({ name, body }); return {}; },
    });
    expect(result.ok).toBe(true);
    expect(calls).toEqual([{ name: 'create-task', body: {
      operation_id: '00000000-0000-4000-8000-000000000123', title: '水着を準備',
      scheduled_date: '2026-09-08', completion_mode: 'all_assignees', calendar_visibility: 'visible',
    } }]);
  });

  it('resolves a role to the household member for requests', async () => {
    const calls: Array<{ name: string; body: Record<string, unknown> }> = [];
    const papa = member('00000000-0000-4000-8000-000000000011', 'papa');
    const mama = member('00000000-0000-4000-8000-000000000012', 'mama');
    const result = await commitConciergeCandidate({
      candidateId: 'request-1', kind: 'request', title: '金曜のお迎え', sourceText: '金曜のお迎えお願い', missingFields: [], intent: { targetRole: 'mama' },
    }, {
      members: [papa, mama], me: papa, partner: mama, timeZone: 'Asia/Tokyo',
      operationId: () => '00000000-0000-4000-8000-000000000124',
      invoke: async (name, body) => { calls.push({ name, body: body as Record<string, unknown> }); return {}; },
    });
    expect(result.ok).toBe(true);
    expect(calls[0]?.name).toBe('send-request');
    expect(calls[0]?.body.target_user_id).toBe(mama.user_id);
  });

  it('never synthesizes an unplanned actual through two non-atomic commands', async () => {
    let called = false;
    const result = await commitConciergeCandidate({
      candidateId: 'actual-1', kind: 'actual', title: '掃除機', sourceText: '掃除機かけた', missingFields: [], intent: { scheduledDate: '2026-09-07' },
    }, {
      members: [], me: null, partner: null, timeZone: 'Asia/Tokyo', invoke: async () => { called = true; return {}; },
    });
    expect(result.ok).toBe(false);
    expect(called).toBe(false);
  });
});
