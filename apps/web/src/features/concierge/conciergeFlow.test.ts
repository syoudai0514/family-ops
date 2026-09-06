import { describe, expect, it } from 'vitest';
import { normalizeConciergeProposal, withActualScheduledDate } from './conciergeFlow';
import { commitConciergeCandidate } from './conciergeCommit';

const member = (userId: string, role: 'papa' | 'mama') => ({
  household_id: '00000000-0000-4000-8000-000000000001', user_id: userId,
  member_role: 'adult' as const, family_role: role, joined_at: '2026-01-01T00:00:00Z', profile: null,
});

describe('Concierge canonical flow', () => {
  it('normalizes the exact shared LINE semantic candidate shape before rendering', () => {
    const proposal = normalizeConciergeProposal({
      read_only_intent: null, clarification: null,
      candidates: [{
        candidateId: 'c1', kind: 'task', title: '水着を準備', sourceText: '明日の水着を準備', missingFields: [],
        intent: { scheduledDate: '2026-09-08', dueLocalTime: null, targetRole: null, sharedMessage: null },
      }],
    }, 'fallback');
    expect(proposal.candidates[0]).toMatchObject({
      candidateId: 'c1', kind: 'task', title: '水着を準備', sourceText: '明日の水着を準備',
      intent: { scheduledDate: '2026-09-08' },
    });
  });

  it('keeps LINE assignee ambiguity intact for human confirmation', () => {
    const proposal = normalizeConciergeProposal({
      read_only_intent: null, clarification: null,
      candidates: [{ candidateId: 'c1', kind: 'request', title: 'お迎え', sourceText: 'お迎えお願い', missingFields: ['assignee'], intent: null }],
    }, 'お迎えお願い');
    expect(proposal.candidates[0]?.missingFields).toEqual(['assignee']);
  });

  it('uses the valid canonical create-task contract only after confirmation', async () => {
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
      scheduled_date: '2026-09-08', completion_mode: 'whole', calendar_visibility: 'hidden',
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

  it('pins the user-selected original target date onto actual candidates', () => {
    const [actual] = withActualScheduledDate([{
      candidateId: 'actual-1', kind: 'actual', title: '掃除機', sourceText: '掃除機かけた', missingFields: [], intent: null,
    }], '2026-09-06');
    expect(actual?.intent?.scheduledDate).toBe('2026-09-06');
  });

  it('records an unplanned actual through one atomic canonical endpoint', async () => {
    const calls: Array<{ name: string; body: object }> = [];
    const result = await commitConciergeCandidate({
      candidateId: 'actual-1', kind: 'actual', title: '掃除機', sourceText: '掃除機かけた', missingFields: [], intent: { scheduledDate: '2026-09-06' },
    }, {
      members: [], me: null, partner: null, timeZone: 'Asia/Tokyo',
      operationId: () => '00000000-0000-4000-8000-000000000125',
      invoke: async (name, body) => { calls.push({ name, body }); return {}; },
    });
    expect(result.ok).toBe(true);
    expect(calls).toEqual([{ name: 'record-unplanned-actual', body: {
      operation_id: '00000000-0000-4000-8000-000000000125', title: '掃除機', scheduled_date: '2026-09-06',
    } }]);
  });
});
