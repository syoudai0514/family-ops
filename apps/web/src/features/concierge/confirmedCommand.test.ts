import { describe, expect, it } from 'vitest';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import type { ConciergeCandidate } from './conciergeFlow';
import { buildConfirmedCommand, requestMessageIsReviewed } from './confirmedCommand';

const members = [
  { household_id: 'h', user_id: 'u1', member_role: 'adult', family_role: 'papa', joined_at: '', profile: { user_id: 'u1', display_name: 'パパ' } },
  { household_id: 'h', user_id: 'u2', member_role: 'adult', family_role: 'mama', joined_at: '', profile: { user_id: 'u2', display_name: 'ママ' } },
] as HouseholdMemberWithProfile[];

const context = { members, me: members[0], partner: members[1], timeZone: 'Asia/Tokyo' };

function candidate(overrides: Partial<ConciergeCandidate> = {}): ConciergeCandidate {
  return {
    candidateId: 'c1', operationId: 'op1', candidateRevision: 1, messageReviewedRevision: 1,
    kind: 'request', title: '水曜のお迎え', sourceText: '火曜のお迎えお願い。これは相手に見せたくない独り言',
    sourceSpan: null, confidence: 1, ambiguousFields: [], missingFields: [], duplicateMatch: null,
    intent: { scheduledDate: '2026-09-23', targetRole: 'mama', sharedMessage: '水曜のお迎えをお願いできる？', subtasks: [], context: null, calendarVisibility: 'hidden' },
    resolvedAction: null,
    ...overrides,
  };
}

describe('confirmed command', () => {
  it('uses the reviewed shared message and never raw source text as request payload', () => {
    const command = buildConfirmedCommand(candidate(), context);
    expect(command.payload.shared_message).toBe('水曜のお迎えをお願いできる？');
    expect(JSON.stringify(command.payload)).not.toContain('相手に見せたくない独り言');
    expect(command.preview.sharedMessage).toBe(command.payload.shared_message);
  });

  it('blocks a request when conditions changed after message review', () => {
    const edited = candidate({ candidateRevision: 2, messageReviewedRevision: 1 });
    expect(requestMessageIsReviewed(edited)).toBe(false);
    expect(() => buildConfirmedCommand(edited, context)).toThrow('送る文面を確認してください。');
  });

  it('keeps preparation items as canonical task subtasks', () => {
    const task = candidate({
      kind: 'task', title: '病院の準備', messageReviewedRevision: null,
      intent: { scheduledDate: '2026-09-20', dueLocalTime: '10:00', targetRole: 'papa', sharedMessage: null, subtasks: ['保険証', '診察券'], context: '皮膚科 11:00', calendarVisibility: 'special' },
    });
    const command = buildConfirmedCommand(task, context);
    expect(command.payload.completion_mode).toBe('subtasks');
    expect(command.payload.subtasks).toEqual([
      { title: '保険証', required: true, sort_order: 1 },
      { title: '診察券', required: true, sort_order: 2 },
    ]);
    expect(command.payload.calendar_visibility).toBe('special');
    expect(command.preview.subtaskLabels).toEqual(['保険証', '診察券']);
  });

  it('uses the existing assignment-change command when resolver identified pickup', () => {
    const assignment = candidate({
      resolvedAction: { type: 'assignment_change_request', taskId: 't1', taskRevision: 3, recipientUserId: 'u2', scope: 'once', scheduledDate: '2026-09-23', dueAt: null, currentAssigneeId: 'u1' },
    });
    const command = buildConfirmedCommand(assignment, context);
    expect(command.endpoint).toBe('create-assignment-change-request');
    expect(command.payload).toMatchObject({ task_id: 't1', recipient_user_id: 'u2', expected_task_revision: 3, scope: 'once' });
  });
});
