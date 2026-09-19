import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import { EDGE_FUNCTIONS, type EdgeFunctionName } from '../../lib/edgeFunctions';
import type { ConciergeCandidate } from './conciergeFlow';
import type { DuplicateDecision } from './conciergeCommit';

export type ConfirmedCommand = {
  candidateId: string;
  operationId: string;
  candidateRevision: number;
  endpoint: EdgeFunctionName;
  payload: Record<string, unknown>;
  preview: {
    title: string;
    recipientLabel?: string;
    sharedMessage?: string;
    dateLabel?: string;
    timeLabel?: string;
    scopeLabel?: string;
    impactLabels: string[];
    subtaskLabels?: string[];
  };
};

export type ConfirmedCommandContext = {
  members: HouseholdMemberWithProfile[];
  me: HouseholdMemberWithProfile | null;
  partner: HouseholdMemberWithProfile | null;
  timeZone: string;
};

function dateInTimeZone(timeZone: string): string {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date());
  const pick = (type: Intl.DateTimeFormatPartTypes) => parts.find((part) => part.type === type)?.value ?? '';
  return `${pick('year')}-${pick('month')}-${pick('day')}`;
}

function dueAt(candidate: ConciergeCandidate): string | null {
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

function resolveTarget(candidate: ConciergeCandidate, context: ConfirmedCommandContext): string | null {
  const direct = candidate.intent?.targetUserId;
  if (direct) return direct;
  const role = candidate.intent?.targetRole;
  if (!role) return null;
  return context.members.find((member) => member.family_role === role)?.user_id ?? null;
}

function targetLabel(candidate: ConciergeCandidate, context: ConfirmedCommandContext, targetUserId: string | null): string | undefined {
  if (!targetUserId) return undefined;
  const member = context.members.find((row) => row.user_id === targetUserId);
  return member?.profile?.display_name ?? (member?.family_role === 'papa' ? 'パパ' : member?.family_role === 'mama' ? 'ママ' : '家族');
}

function taskTitle(candidate: ConciergeCandidate): string {
  const context = candidate.intent?.context?.trim();
  if (!context || candidate.title.includes(context)) return candidate.title;
  const combined = `${candidate.title}（${context}）`;
  if (combined.length > 80) throw new Error('予定の補足を含めるとタイトルが長すぎます。内容を短くして確認してください。');
  return combined;
}

export function requestMessageIsReviewed(candidate: ConciergeCandidate): boolean {
  if (candidate.kind !== 'request') return true;
  return Boolean(candidate.intent?.sharedMessage?.trim()) &&
    candidate.messageReviewedRevision === (candidate.candidateRevision ?? 1);
}

export function buildConfirmedCommand(
  candidate: ConciergeCandidate,
  context: ConfirmedCommandContext,
  duplicateDecision?: DuplicateDecision,
): ConfirmedCommand {
  if (!candidate.operationId) throw new Error('安全な再試行IDがありません。候補を作り直してください。');
  if (candidate.missingFields.length > 0) throw new Error(`未確定: ${candidate.missingFields.join(' / ')}`);

  const scheduledDate = candidate.intent?.scheduledDate ?? dateInTimeZone(context.timeZone);
  const targetUserId = resolveTarget(candidate, context);
  const previewBase = {
    title: candidate.title,
    dateLabel: scheduledDate,
    timeLabel: candidate.intent?.dueLocalTime ?? undefined,
    impactLabels: [] as string[],
  };

  if (candidate.duplicateMatch && duplicateDecision === 'update') {
    if (candidate.duplicateMatch.entityKind !== 'task' && candidate.duplicateMatch.entityKind !== 'shopping') {
      throw new Error('この種類は既存更新に対応していません。');
    }
    return {
      candidateId: candidate.candidateId,
      operationId: candidate.operationId,
      candidateRevision: candidate.candidateRevision ?? 1,
      endpoint: EDGE_FUNCTIONS.commitConciergeDuplicate,
      payload: {
        operation_id: candidate.operationId,
        entity_kind: candidate.duplicateMatch.entityKind,
        entity_id: candidate.duplicateMatch.entityId,
        expected_revision: candidate.duplicateMatch.expectedRevision,
        title: candidate.title,
        scheduled_date: candidate.intent?.scheduledDate ?? null,
        due_local_time: candidate.intent?.dueLocalTime ?? null,
        planned_assignee_user_id: candidate.kind === 'task' ? targetUserId : null,
      },
      preview: previewBase,
    };
  }

  if (candidate.kind === 'task') {
    const subtasks = (candidate.intent?.subtasks ?? []).map((title, index) => ({ title, required: true, sort_order: index + 1 }));
    return {
      candidateId: candidate.candidateId,
      operationId: candidate.operationId,
      candidateRevision: candidate.candidateRevision ?? 1,
      endpoint: EDGE_FUNCTIONS.createTask,
      payload: {
        operation_id: candidate.operationId,
        title: taskTitle(candidate),
        scheduled_date: scheduledDate,
        due_local_time: candidate.intent?.dueLocalTime ?? null,
        planned_assignee_user_id: targetUserId,
        completion_mode: subtasks.length > 0 ? 'subtasks' : 'whole',
        calendar_visibility: candidate.intent?.calendarVisibility ?? 'hidden',
        subtasks: subtasks.length > 0 ? subtasks : null,
      },
      preview: { ...previewBase, title: taskTitle(candidate), subtaskLabels: subtasks.map((item) => item.title) },
    };
  }

  if (candidate.kind === 'shopping') {
    return {
      candidateId: candidate.candidateId,
      operationId: candidate.operationId,
      candidateRevision: candidate.candidateRevision ?? 1,
      endpoint: EDGE_FUNCTIONS.addShoppingItem,
      payload: {
        operation_id: candidate.operationId,
        title: candidate.title,
        purchase_method: 'store',
        due_at: shoppingDueAt(candidate),
        assignment_mode: 'unassigned',
        duplicate_sensitivity: 'avoid_duplicate',
      },
      preview: previewBase,
    };
  }

  if (candidate.kind === 'share') {
    return {
      candidateId: candidate.candidateId,
      operationId: candidate.operationId,
      candidateRevision: candidate.candidateRevision ?? 1,
      endpoint: EDGE_FUNCTIONS.createHandover,
      payload: {
        operation_id: candidate.operationId,
        shared_text: candidate.intent?.sharedMessage?.trim() || candidate.title,
        occurred_on: scheduledDate,
        period: 'other',
        categories: [],
      },
      preview: { ...previewBase, sharedMessage: candidate.intent?.sharedMessage?.trim() || candidate.title },
    };
  }

  if (candidate.kind === 'request') {
    if (!requestMessageIsReviewed(candidate)) throw new Error('送る文面を確認してください。');
    const sharedMessage = candidate.intent?.sharedMessage?.trim();
    if (!sharedMessage) throw new Error('送る文面を入力してください。');

    if (candidate.resolvedAction?.type === 'assignment_change_request') {
      return {
        candidateId: candidate.candidateId,
        operationId: candidate.operationId,
        candidateRevision: candidate.candidateRevision ?? 1,
        endpoint: EDGE_FUNCTIONS.createAssignmentChangeRequest,
        payload: {
          operation_id: candidate.operationId,
          task_id: candidate.resolvedAction.taskId,
          recipient_user_id: candidate.resolvedAction.recipientUserId,
          shared_message: sharedMessage,
          scope: candidate.resolvedAction.scope,
          expected_task_revision: candidate.resolvedAction.taskRevision,
        },
        preview: {
          ...previewBase,
          recipientLabel: targetLabel(candidate, context, candidate.resolvedAction.recipientUserId),
          sharedMessage,
          scopeLabel: candidate.resolvedAction.scope === 'this_week' ? '今週だけ' : '今回だけ',
          dateLabel: candidate.resolvedAction.scheduledDate,
        },
      };
    }

    if (!targetUserId) throw new Error('お願い先が確定していません。');
    return {
      candidateId: candidate.candidateId,
      operationId: candidate.operationId,
      candidateRevision: candidate.candidateRevision ?? 1,
      endpoint: EDGE_FUNCTIONS.sendRequest,
      payload: {
        operation_id: candidate.operationId,
        recipient_user_id: targetUserId,
        shared_title: candidate.title,
        shared_message: sharedMessage,
        due_at: dueAt(candidate),
      },
      preview: { ...previewBase, recipientLabel: targetLabel(candidate, context, targetUserId), sharedMessage },
    };
  }

  return {
    candidateId: candidate.candidateId,
    operationId: candidate.operationId,
    candidateRevision: candidate.candidateRevision ?? 1,
    endpoint: EDGE_FUNCTIONS.recordUnplannedActual,
    payload: { operation_id: candidate.operationId, title: candidate.title, scheduled_date: scheduledDate },
    preview: previewBase,
  };
}
