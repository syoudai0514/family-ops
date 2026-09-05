// verify_jwt=true. This is the explicit "already agreed" path: it calls the
// canonical assignment command and never creates a request/approval row.
import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  if (typeof body.task_id !== 'string' || typeof body.assignee_user_id !== 'string' ||
      typeof body.expected_revision !== 'number' || !Number.isSafeInteger(body.expected_revision) ||
      body.already_agreed !== true) {
    throw new FamilyOpsError('INVALID_INPUT', 'task_id, assignee_user_id, expected_revision and already_agreed=true are required', 400);
  }
  const service = createServiceRoleClient();
  const { data: actorMember, error: actorError } = await service
    .from('household_members').select('household_id').eq('user_id', actorId).maybeSingle();
  if (actorError || !actorMember) throw new FamilyOpsError('NOT_HOUSEHOLD_MEMBER', '世帯情報を確認できません。', 403);
  const { data: assigneeRef, error: refError } = await service
    .from('domain_actor_refs').select('id')
    .eq('household_id', actorMember.household_id).eq('actor_kind', 'real_user')
    .eq('real_user_id', body.assignee_user_id).maybeSingle();
  if (refError || !assigneeRef) throw new FamilyOpsError('INVALID_INPUT', '担当者を確認できません。', 400);
  return jsonResponse(await callServerTx(service, 'server_tx_change_task_assignment', {
    p_actor_id: actorId, p_operation_id: operationId, p_task_id: body.task_id,
    p_assignment_mode: 'person', p_assignee_actor_ref_id: assigneeRef.id,
    p_already_agreed: true, p_expected_revision: body.expected_revision,
  }));
}));
