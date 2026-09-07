import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS, type EdgeFunctionName } from '../../lib/edgeFunctions';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import type { ConciergeCandidate } from './conciergeFlow';

type EdgeInvoker = (name: EdgeFunctionName, body: object) => Promise<unknown>;

export type ConciergeCommitResult = {
  candidateId: string;
  kind: ConciergeCandidate['kind'];
  title: string;
  ok: boolean;
  message: string;
};

type CommitContext = {
  members: HouseholdMemberWithProfile[];
  me: HouseholdMemberWithProfile | null;
  partner: HouseholdMemberWithProfile | null;
  timeZone: string;
  invoke?: EdgeInvoker;
  operationId?: () => string;
};

function dateInTimeZone(timeZone: string): string {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date());
  const pick = (type: Intl.DateTimeFormatPartTypes) => parts.find((part) => part.type === type)?.value ?? '';
  return `${pick('year')}-${pick('month')}-${pick('day')}`;
}

export function conciergeRequestDueAt(candidate: ConciergeCandidate): string | null {
  const scheduledDate = candidate.intent?.scheduledDate;
  if (!scheduledDate) return candidate.intent?.desiredDueAt ?? null;
  const localTime = candidate.intent?.dueLocalTime ?? '23:59';
  const parsed = new Date(`${scheduledDate}T${localTime}:00+09:00`);
  return Number.isNaN(parsed.getTime()) ? candidate.intent?.desiredDueAt ?? null : parsed.toISOString();
}

function resolveTarget(candidate: ConciergeCandidate, context: CommitContext): string | null {
  const direct = candidate.intent?.targetUserId;
  if (direct) return direct;
  const role = candidate.intent?.targetRole;
  if (role) return context.members.find((member) => member.family_role === role)?.user_id ?? null;
  return candidate.kind === 'request' ? context.partner?.user_id ?? null : null;
}

function result(candidate: ConciergeCandidate, ok: boolean, message: string): ConciergeCommitResult {
  return { candidateId: candidate.candidateId, kind: candidate.kind, title: candidate.title, ok, message };
}

export async function commitConciergeCandidate(candidate: ConciergeCandidate, context: CommitContext): Promise<ConciergeCommitResult> {
  if (candidate.missingFields.length > 0) return result(candidate, false, `未確定: ${candidate.missingFields.join(' / ')}`);

  const invoke = context.invoke ?? ((name, body) => callEdgeFunction(name, body));
  const operationId = context.operationId ?? (() => crypto.randomUUID());
  const scheduledDate = candidate.intent?.scheduledDate ?? dateInTimeZone(context.timeZone);
  const targetUserId = resolveTarget(candidate, context);

  try {
    if (candidate.kind === 'task') {
      await invoke(EDGE_FUNCTIONS.createTask, {
        operation_id: operationId(), title: candidate.title, scheduled_date: scheduledDate,
        completion_mode: 'whole', calendar_visibility: 'hidden',
      });
    } else if (candidate.kind === 'shopping') {
      await invoke(EDGE_FUNCTIONS.addShoppingItem, {
        operation_id: operationId(), name: candidate.title,
        due_date: candidate.intent?.scheduledDate ?? null,
        priority: candidate.intent?.priority ?? 'normal', assignment_mode: 'unassigned',
      });
    } else if (candidate.kind === 'share') {
      await invoke(EDGE_FUNCTIONS.createHandover, {
        operation_id: operationId(), body: candidate.intent?.sharedMessage?.trim() || candidate.title,
        target_user_id: targetUserId, occurred_on: scheduledDate, period: 'other', categories: [],
      });
    } else if (candidate.kind === 'request') {
      if (!targetUserId) return result(candidate, false, 'お願い先が確定していません。');
      await invoke(EDGE_FUNCTIONS.sendRequest, {
        operation_id: operationId(),
        recipient_user_id: targetUserId,
        shared_title: candidate.title,
        shared_message: candidate.intent?.sharedMessage?.trim() || candidate.sourceText,
        due_at: conciergeRequestDueAt(candidate),
      });
    } else if (candidate.kind === 'actual') {
      await invoke(EDGE_FUNCTIONS.recordUnplannedActual, {
        operation_id: operationId(), title: candidate.title, scheduled_date: scheduledDate,
      });
    }
    return result(candidate, true, '登録しました');
  } catch (error) {
    return result(candidate, false, error instanceof Error ? error.message : '登録に失敗しました。');
  }
}

export async function commitConciergeCandidates(candidates: ConciergeCandidate[], context: CommitContext): Promise<ConciergeCommitResult[]> {
  const results: ConciergeCommitResult[] = [];
  for (const candidate of candidates) results.push(await commitConciergeCandidate(candidate, context));
  return results;
}
