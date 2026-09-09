import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS, type EdgeFunctionName } from '../../lib/edgeFunctions';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import type { ConciergeCandidate } from './conciergeFlow';

export type DuplicateDecision = 'existing' | 'update' | 'separate';
type EdgeInvoker = (name: EdgeFunctionName, body: object) => Promise<unknown>;

export type ConciergeCommitResult = {
  candidateId: string;
  operationId: string;
  kind: ConciergeCandidate['kind'];
  title: string;
  ok: boolean;
  message: string;
  canonicalResult?: unknown;
};

type CommitContext = {
  members: HouseholdMemberWithProfile[];
  me: HouseholdMemberWithProfile | null;
  partner: HouseholdMemberWithProfile | null;
  timeZone: string;
  invoke?: EdgeInvoker;
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

function shoppingDueAt(candidate: ConciergeCandidate): string | null {
  const date = candidate.intent?.scheduledDate;
  if (!date) return null;
  const time = candidate.intent?.dueLocalTime ?? '23:59';
  const parsed = new Date(`${date}T${time}:00+09:00`);
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
}

function resolveTarget(candidate: ConciergeCandidate, context: CommitContext): string | null {
  const direct = candidate.intent?.targetUserId;
  if (direct) return direct;
  const role = candidate.intent?.targetRole;
  if (role) return context.members.find((member) => member.family_role === role)?.user_id ?? null;
  return candidate.kind === 'request' ? context.partner?.user_id ?? null : null;
}

function result(
  candidate: ConciergeCandidate,
  ok: boolean,
  message: string,
  canonicalResult?: unknown,
): ConciergeCommitResult {
  return {
    candidateId: candidate.candidateId,
    operationId: candidate.operationId,
    kind: candidate.kind,
    title: candidate.title,
    ok,
    message,
    canonicalResult,
  };
}

export async function commitConciergeCandidate(
  candidate: ConciergeCandidate,
  context: CommitContext,
  duplicateDecision?: DuplicateDecision,
): Promise<ConciergeCommitResult> {
  if (candidate.missingFields.length > 0) return result(candidate, false, `未確定: ${candidate.missingFields.join(' / ')}`);
  if (!candidate.operationId) return result(candidate, false, '安全な再試行IDがありません。候補を作り直してください。');
  if (candidate.duplicateMatch && !duplicateDecision) return result(candidate, false, '重複候補の扱いが未確定です。');

  // "既存を使う" is explicitly a no-business-write path.
  if (candidate.duplicateMatch && duplicateDecision === 'existing') {
    return result(candidate, true, '既存を使うため変更しません');
  }

  const invoke = context.invoke ?? ((name, body) => callEdgeFunction(name, body));
  const scheduledDate = candidate.intent?.scheduledDate ?? dateInTimeZone(context.timeZone);
  const targetUserId = resolveTarget(candidate, context);

  try {
    // "既存を更新" has its own CAS endpoint. There is deliberately no catch
    // branch that converts a conflict into a create.
    if (candidate.duplicateMatch && duplicateDecision === 'update') {
      if (candidate.duplicateMatch.entityKind !== 'task' && candidate.duplicateMatch.entityKind !== 'shopping') {
        return result(candidate, false, 'この種類は既存更新に対応していません。別物として追加するか既存を使ってください。');
      }
      const canonicalResult = await invoke(EDGE_FUNCTIONS.commitConciergeDuplicate, {
        operation_id: candidate.operationId,
        entity_kind: candidate.duplicateMatch.entityKind,
        entity_id: candidate.duplicateMatch.entityId,
        expected_revision: candidate.duplicateMatch.expectedRevision,
        title: candidate.title,
        scheduled_date: candidate.intent?.scheduledDate ?? null,
        due_local_time: candidate.intent?.dueLocalTime ?? null,
        planned_assignee_user_id: candidate.kind === 'task' ? targetUserId : null,
      });
      return result(candidate, true, '既存を更新しました', canonicalResult);
    }

    let canonicalResult: unknown;
    if (candidate.kind === 'task') {
      canonicalResult = await invoke(EDGE_FUNCTIONS.createTask, {
        operation_id: candidate.operationId,
        title: candidate.title,
        scheduled_date: scheduledDate,
        due_local_time: candidate.intent?.dueLocalTime ?? null,
        planned_assignee_user_id: targetUserId,
        completion_mode: 'whole',
        calendar_visibility: 'hidden',
      });
    } else if (candidate.kind === 'shopping') {
      canonicalResult = await invoke(EDGE_FUNCTIONS.addShoppingItem, {
        operation_id: candidate.operationId,
        title: candidate.title,
        purchase_method: 'store',
        due_at: shoppingDueAt(candidate),
        assignment_mode: 'unassigned',
        duplicate_sensitivity: 'avoid_duplicate',
      });
    } else if (candidate.kind === 'share') {
      canonicalResult = await invoke(EDGE_FUNCTIONS.createHandover, {
        operation_id: candidate.operationId,
        shared_text: candidate.intent?.sharedMessage?.trim() || candidate.title,
        occurred_on: scheduledDate,
        period: 'other',
        categories: [],
      });
    } else if (candidate.kind === 'request') {
      if (!targetUserId) return result(candidate, false, 'お願い先が確定していません。');
      canonicalResult = await invoke(EDGE_FUNCTIONS.sendRequest, {
        operation_id: candidate.operationId,
        recipient_user_id: targetUserId,
        shared_title: candidate.title,
        shared_message: candidate.intent?.sharedMessage?.trim() || candidate.sourceText,
        due_at: conciergeRequestDueAt(candidate),
      });
    } else if (candidate.kind === 'actual') {
      canonicalResult = await invoke(EDGE_FUNCTIONS.recordUnplannedActual, {
        operation_id: candidate.operationId,
        title: candidate.title,
        scheduled_date: scheduledDate,
      });
    }
    return result(candidate, true, '登録しました', canonicalResult);
  } catch (error) {
    return result(candidate, false, error instanceof Error ? error.message : '登録に失敗しました。');
  }
}

export async function commitConciergeCandidates(
  candidates: ConciergeCandidate[],
  context: CommitContext,
  duplicateDecisions: Record<string, DuplicateDecision> = {},
): Promise<ConciergeCommitResult[]> {
  const results: ConciergeCommitResult[] = [];
  for (const candidate of candidates) {
    results.push(await commitConciergeCandidate(candidate, context, duplicateDecisions[candidate.candidateId]));
  }
  return results;
}
