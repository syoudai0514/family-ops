import { describe, expect, it } from 'vitest';
import { normalizeConciergeProposal, withActualScheduledDate, type ConciergeCandidate } from './conciergeFlow';
import { commitConciergeCandidate, conciergeRequestDueAt } from './conciergeCommit';

const member = (userId: string, role: 'papa' | 'mama') => ({
  household_id: '00000000-0000-4000-8000-000000000001', user_id: userId,
  member_role: 'adult' as const, family_role: role, joined_at: '2026-01-01T00:00:00Z', profile: null,
});

function candidate(overrides: Partial<ConciergeCandidate> & Pick<ConciergeCandidate, 'candidateId' | 'kind' | 'title'>): ConciergeCandidate {
  return {
    operationId: `00000000-0000-4000-8000-${overrides.candidateId.padEnd(12, '0').slice(0, 12)}`,
    sourceText: overrides.title,
    sourceSpan: null,
    confidence: null,
    ambiguousFields: [],
    missingFields: [],
    duplicateMatch: null,
    intent: null,
    ...overrides,
  };
}

const context = (invoke: (name: string, body: object) => Promise<unknown>) => ({
  members: [], me: null, partner: null, timeZone: 'Asia/Tokyo', invoke,
});

describe('Concierge canonical flow', () => {
  it('normalizes shared semantic metadata and stable operation identity before rendering', () => {
    const proposal = normalizeConciergeProposal({
      read_only_intent: null, clarification: null,
      candidates: [{
        candidateId: 'c1', operationId: '00000000-0000-4000-8000-000000000101',
        kind: 'task', title: '水着を準備', sourceText: '明日の水着を準備',
        sourceSpan: { start: 0, end: 9 }, confidence: 0.94, ambiguousFields: [], missingFields: [],
        duplicateMatch: null,
        intent: { scheduledDate: '2026-09-08', dueLocalTime: null, targetRole: null, sharedMessage: null },
      }],
    }, 'fallback');
    expect(proposal.candidates[0]).toMatchObject({
      candidateId: 'c1', operationId: '00000000-0000-4000-8000-000000000101',
      kind: 'task', title: '水着を準備', sourceText: '明日の水着を準備',
      sourceSpan: { start: 0, end: 9 }, confidence: 0.94,
      intent: { scheduledDate: '2026-09-08' },
    });
  });

  it('fails closed when the proposal did not pre-issue operation identity', () => {
    const proposal = normalizeConciergeProposal({
      read_only_intent: null, clarification: null,
      candidates: [{
        candidateId: 'c1', operationId: '', kind: 'task', title: '水着を準備', sourceText: '水着を準備',
        missingFields: [], intent: { scheduledDate: '2026-09-08' },
      }],
    }, 'fallback');
    expect(proposal.candidates).toEqual([]);
  });

  it('keeps exactly one ambiguous assignee for human clarification', () => {
    const proposal = normalizeConciergeProposal({
      read_only_intent: null, clarification: null,
      candidates: [{
        candidateId: 'c1', operationId: '00000000-0000-4000-8000-000000000102',
        kind: 'request', title: 'お迎え', sourceText: 'お迎えお願い',
        ambiguousFields: ['assignee'], missingFields: ['assignee'], intent: null,
      }],
    }, 'お迎えお願い');
    expect(proposal.candidates[0]?.missingFields).toEqual(['assignee']);
    expect(proposal.candidates[0]?.ambiguousFields).toEqual(['assignee']);
  });

  it('uses the current canonical create-task contract with the candidate operation id', async () => {
    const calls: Array<{ name: string; body: object }> = [];
    const task = candidate({
      candidateId: 'task-1', operationId: '00000000-0000-4000-8000-000000000123',
      kind: 'task', title: '水着を準備', sourceText: '水着を準備', intent: { scheduledDate: '2026-09-08' },
    });
    const result = await commitConciergeCandidate(task, context(async (name, body) => { calls.push({ name, body }); return { task_id: 't1' }; }));
    expect(result.ok).toBe(true);
    expect(calls).toEqual([{ name: 'create-task', body: {
      operation_id: '00000000-0000-4000-8000-000000000123', title: '水着を準備',
      scheduled_date: '2026-09-08', due_local_time: null, planned_assignee_user_id: null,
      completion_mode: 'whole', calendar_visibility: 'hidden',
    } }]);
  });

  it('implements the three duplicate decisions without semantic collapse', async () => {
    const matched = candidate({
      candidateId: 'dup-1', operationId: '00000000-0000-4000-8000-000000000130',
      kind: 'task', title: 'ゴミ出し', sourceText: '明日ゴミ出し', intent: { scheduledDate: '2026-09-10' },
      duplicateMatch: {
        entityKind: 'task', entityId: '00000000-0000-4000-8000-000000000900', expectedRevision: 7,
        evidence: { strategy: 'canonical_exact', matchedTitle: 'ゴミ出し', matchedDate: '2026-09-09' },
      },
    });

    const existingCalls: unknown[] = [];
    const existing = await commitConciergeCandidate(matched, context(async (...args) => { existingCalls.push(args); return {}; }), 'existing');
    expect(existing.ok).toBe(true);
    expect(existingCalls).toHaveLength(0);

    const updateCalls: Array<{ name: string; body: object }> = [];
    const update = await commitConciergeCandidate(matched, context(async (name, body) => { updateCalls.push({ name, body }); return { entity_id: matched.duplicateMatch?.entityId, revision: 8 }; }), 'update');
    expect(update.ok).toBe(true);
    expect(updateCalls).toEqual([{ name: 'commit-concierge-duplicate', body: {
      operation_id: matched.operationId,
      entity_kind: 'task', entity_id: matched.duplicateMatch?.entityId, expected_revision: 7,
      title: 'ゴミ出し', scheduled_date: '2026-09-10', due_local_time: null,
      planned_assignee_user_id: null,
    } }]);

    const separateCalls: Array<{ name: string; body: object }> = [];
    const separate = await commitConciergeCandidate(matched, context(async (name, body) => { separateCalls.push({ name, body }); return { task_id: 'new-task' }; }), 'separate');
    expect(separate.ok).toBe(true);
    expect(separateCalls[0]?.name).toBe('create-task');
  });

  it('never falls back from a stale duplicate update to create', async () => {
    const matched = candidate({
      candidateId: 'dup-2', operationId: '00000000-0000-4000-8000-000000000131',
      kind: 'task', title: 'ゴミ出し', intent: { scheduledDate: '2026-09-10' },
      duplicateMatch: {
        entityKind: 'task', entityId: '00000000-0000-4000-8000-000000000901', expectedRevision: 3,
        evidence: { strategy: 'canonical_exact', matchedTitle: 'ゴミ出し', matchedDate: '2026-09-09' },
      },
    });
    const calls: string[] = [];
    const result = await commitConciergeCandidate(matched, context(async (name) => {
      calls.push(name);
      throw new Error('AGGREGATE_REVISION_CONFLICT');
    }), 'update');
    expect(result.ok).toBe(false);
    expect(result.message).toContain('AGGREGATE_REVISION_CONFLICT');
    expect(calls).toEqual(['commit-concierge-duplicate']);
  });

  it('retries response loss with the same operation identity and replays one canonical outcome', async () => {
    const task = candidate({
      candidateId: 'retry-1', operationId: '00000000-0000-4000-8000-000000000140',
      kind: 'task', title: 'ゴミ出し', intent: { scheduledDate: '2026-09-10' },
    });
    const rows: Array<{ id: string; operationId: string }> = [];
    const outbox: string[] = [];
    const receipts = new Map<string, { task_id: string; receipt: 'replay' | 'committed' }>();
    let loseResponse = true;
    const invoke = async (_name: string, body: object) => {
      const op = String((body as Record<string, unknown>).operation_id);
      const replay = receipts.get(op);
      if (replay) return { ...replay, receipt: 'replay' as const };
      const canonical = { task_id: 'task-original', receipt: 'committed' as const };
      rows.push({ id: canonical.task_id, operationId: op });
      outbox.push(`task-created:${canonical.task_id}`);
      receipts.set(op, canonical);
      if (loseResponse) {
        loseResponse = false;
        throw new Error('NETWORK_RESPONSE_LOST');
      }
      return canonical;
    };

    const first = await commitConciergeCandidate(task, context(invoke));
    expect(first.ok).toBe(false);
    const retry = await commitConciergeCandidate(task, context(invoke));
    expect(retry.ok).toBe(true);
    expect(rows).toHaveLength(1);
    expect(outbox).toHaveLength(1);
    expect(receipts.size).toBe(1);
    expect(retry.canonicalResult).toEqual({ task_id: 'task-original', receipt: 'replay' });
  });

  it('preserves corrected request date and current send-request API contract', async () => {
    const calls: Array<{ name: string; body: Record<string, unknown> }> = [];
    const papa = member('00000000-0000-4000-8000-000000000011', 'papa');
    const mama = member('00000000-0000-4000-8000-000000000012', 'mama');
    const request = candidate({
      candidateId: 'request-1', operationId: '00000000-0000-4000-8000-000000000124',
      kind: 'request', title: 'お迎え', sourceText: '金曜のお迎えママお願い / 訂正: あ、やっぱ土曜',
      intent: { targetRole: 'mama', scheduledDate: '2026-09-12', dueLocalTime: null, sharedMessage: '土曜のお迎えをお願いできますか？' },
    });
    expect(conciergeRequestDueAt(request)).toBe('2026-09-12T14:59:00.000Z');
    const result = await commitConciergeCandidate(request, {
      members: [papa, mama], me: papa, partner: mama, timeZone: 'Asia/Tokyo',
      invoke: async (name, body) => { calls.push({ name, body: body as Record<string, unknown> }); return {}; },
    });
    expect(result.ok).toBe(true);
    expect(calls).toEqual([{ name: 'send-request', body: {
      operation_id: '00000000-0000-4000-8000-000000000124',
      recipient_user_id: mama.user_id,
      shared_title: 'お迎え', shared_message: '土曜のお迎えをお願いできますか？',
      due_at: '2026-09-12T14:59:00.000Z',
    } }]);
  });

  it('pins the user-selected original target date onto actual candidates', () => {
    const [actual] = withActualScheduledDate([candidate({
      candidateId: 'actual-1', kind: 'actual', title: '掃除機', sourceText: '掃除機かけた',
    })], '2026-09-06');
    expect(actual?.intent?.scheduledDate).toBe('2026-09-06');
    expect(actual?.operationId).toBeTruthy();
  });

  it('records an unplanned actual through one atomic canonical endpoint', async () => {
    const calls: Array<{ name: string; body: object }> = [];
    const actual = candidate({
      candidateId: 'actual-1', operationId: '00000000-0000-4000-8000-000000000125',
      kind: 'actual', title: '掃除機', sourceText: '掃除機かけた', intent: { scheduledDate: '2026-09-06' },
    });
    const result = await commitConciergeCandidate(actual, context(async (name, body) => { calls.push({ name, body }); return {}; }));
    expect(result.ok).toBe(true);
    expect(calls).toEqual([{ name: 'record-unplanned-actual', body: {
      operation_id: '00000000-0000-4000-8000-000000000125', title: '掃除機', scheduled_date: '2026-09-06',
    } }]);
  });
});
