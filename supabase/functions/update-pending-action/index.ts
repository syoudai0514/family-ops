// verify_jwt=true — sender-only PWA edit of a LINE-created pending draft.
// This changes no task, request, or notification itself: the normal explicit
// confirm-pending-action path still owns execution.  The RPC additionally
// guards actor, source=line, draft status, and expiry.
import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { FamilyOpsError } from '../_shared/errors.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody } from '../_shared/rpc.ts';

type ActionType = 'task_create_once' | 'request_create' | 'shopping_item_add';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;

function requiredText(value: unknown, max: number, field: string): string {
  if (typeof value !== 'string')
    throw new FamilyOpsError('INVALID_INPUT', `${field} is required`, 400);
  const text = value.trim();
  if (!text || text.length > max)
    throw new FamilyOpsError('INVALID_INPUT', `${field} is invalid`, 400);
  return text;
}

function optionalTime(value: unknown): string | null {
  if (value === null || value === undefined || value === '') return null;
  if (typeof value !== 'string' || !TIME_RE.test(value)) {
    throw new FamilyOpsError('INVALID_INPUT', 'due_local_time is invalid', 400);
  }
  return value;
}

function date(value: unknown): string {
  const candidate = requiredText(value, 10, 'scheduled_date');
  if (!DATE_RE.test(candidate) || Number.isNaN(new Date(`${candidate}T00:00:00Z`).getTime())) {
    throw new FamilyOpsError('INVALID_INPUT', 'scheduled_date is invalid', 400);
  }
  return candidate;
}

function optionalMember(value: unknown, field: string): string | null {
  if (value === null || value === undefined || value === '') return null;
  if (typeof value !== 'string' || !UUID_RE.test(value)) {
    throw new FamilyOpsError('INVALID_INPUT', `${field} is invalid`, 400);
  }
  return value;
}

function retainedText(payload: Record<string, unknown>, key: string, max: number): string | null {
  const value = payload[key];
  return typeof value === 'string' && value.trim().length > 0 && value.trim().length <= max
    ? value.trim()
    : null;
}

function retainedSubtasks(payload: Record<string, unknown>): string[] | null {
  if (!Array.isArray(payload.subtasks)) return null;
  const values = payload.subtasks
    .filter((item): item is string => typeof item === 'string')
    .map((item) => item.trim())
    .filter((item) => item.length > 0 && item.length <= 60)
    .slice(0, 5);
  return values.length > 0 ? values : null;
}

async function assertHouseholdMember(
  client: ReturnType<typeof createServiceRoleClient>,
  householdId: string,
  userId: string | null,
): Promise<void> {
  if (!userId) return;
  const { data, error } = await client
    .from('household_members')
    .select('user_id')
    .eq('household_id', householdId)
    .eq('user_id', userId)
    .maybeSingle();
  if (error || !data) throw new FamilyOpsError('INVALID_INPUT', '担当者がこの家庭にいません', 400);
}

Deno.serve(
  withUserMutationHandler(async (req: Request) => {
    const actorId = await requireUserActor(req);
    const body = await readJsonBody(req);
    const pendingActionId = requiredText(body.pending_action_id, 36, 'pending_action_id');
    if (!UUID_RE.test(pendingActionId))
      throw new FamilyOpsError('INVALID_INPUT', 'pending_action_id is invalid', 400);
    const actionType = body.action_type;
    if (
      actionType !== 'task_create_once' &&
      actionType !== 'request_create' &&
      actionType !== 'shopping_item_add'
    ) {
      throw new FamilyOpsError('INVALID_INPUT', 'action_type is invalid', 400);
    }
    const incoming = body.normalized_payload;
    if (typeof incoming !== 'object' || incoming === null || Array.isArray(incoming)) {
      throw new FamilyOpsError('INVALID_INPUT', 'normalized_payload is invalid', 400);
    }
    const payload = incoming as Record<string, unknown>;
    const client = createServiceRoleClient();
    const { data: actorMembership, error: membershipError } = await client
      .from('household_members')
      .select('household_id')
      .eq('user_id', actorId)
      .maybeSingle();
    if (membershipError || !actorMembership)
      throw new FamilyOpsError('NOT_HOUSEHOLD_MEMBER', '家庭が見つかりません', 403);

    const normalized: Record<string, unknown> = {
      title: requiredText(payload.title, 120, 'title'),
      scheduled_date: date(payload.scheduled_date),
      due_local_time: optionalTime(payload.due_local_time),
    };
    const rawText = retainedText(payload, 'raw_text', 1000);
    const context = retainedText(payload, 'context', 240);
    const subtasks = retainedSubtasks(payload);
    if (rawText) normalized.raw_text = rawText;
    if (context) normalized.context = context;
    if (subtasks) normalized.subtasks = subtasks;

    if (actionType === 'task_create_once') {
      const assignee =
        optionalMember(payload.planned_assignee_user_id, 'planned_assignee_user_id') ?? actorId;
      await assertHouseholdMember(client, actorMembership.household_id, assignee);
      normalized.category = retainedText(payload, 'category', 48) ?? 'todo';
      normalized.routine_phase = retainedText(payload, 'routine_phase', 24) ?? 'anytime';
      normalized.calendar_visibility =
        payload.calendar_visibility === 'special' ? 'special' : 'hidden';
      normalized.planned_assignee_user_id = assignee;
      normalized.target_label = retainedText(payload, 'target_label', 32) ?? '自分';
    } else if (actionType === 'request_create') {
      const recipient = optionalMember(payload.recipient_user_id, 'recipient_user_id');
      if (!recipient || recipient === actorId) {
        throw new FamilyOpsError('INVALID_INPUT', '依頼先は自分以外の家族を選んでください', 400);
      }
      await assertHouseholdMember(client, actorMembership.household_id, recipient);
      normalized.recipient_user_id = recipient;
      normalized.shared_message = requiredText(payload.shared_message, 500, 'shared_message');
      normalized.target_label = retainedText(payload, 'target_label', 32) ?? 'パートナー';
    } else {
      const assignee = optionalMember(payload.assignee_user_id, 'assignee_user_id');
      await assertHouseholdMember(client, actorMembership.household_id, assignee);
      normalized.assignee_user_id = assignee;
      normalized.purchase_method = retainedText(payload, 'purchase_method', 24) ?? 'store';
      normalized.target_label = retainedText(payload, 'target_label', 32) ?? '買い物リスト';
    }

    const result = await callServerTx(client, 'server_tx_update_pending_action', {
      p_actor_id: actorId,
      p_pending_action_id: pendingActionId,
      p_action_type: actionType,
      p_normalized_payload: normalized,
    });
    return jsonResponse(result);
  }),
);
