// verify_jwt=true. The browser can name household users, never ActorRef IDs;
// this edge derives the production ActorRefs server-side before invoking the
// canonical append-only actual-correction command.
import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  const participantUserIds = Array.isArray(body.participant_user_ids) && body.participant_user_ids.every((id) => typeof id === 'string')
    ? [...new Set(body.participant_user_ids as string[])] : [];
  if (typeof body.task_id !== 'string' || participantUserIds.length === 0 ||
      typeof body.expected_revision !== 'number' || !Number.isSafeInteger(body.expected_revision)) {
    throw new FamilyOpsError('INVALID_INPUT', 'task_id, participant_user_ids and expected_revision are required', 400);
  }
  const service = createServiceRoleClient();
  const { data: member, error: memberError } = await service
    .from('household_members').select('household_id').eq('user_id', actorId).maybeSingle();
  if (memberError || !member) throw new FamilyOpsError('NOT_HOUSEHOLD_MEMBER', '世帯情報を確認できません。', 403);
  const { data: refs, error: refsError } = await service
    .from('domain_actor_refs').select('id, real_user_id')
    .eq('household_id', member.household_id).eq('actor_kind', 'real_user')
    .in('real_user_id', participantUserIds);
  if (refsError || (refs ?? []).length !== participantUserIds.length) {
    throw new FamilyOpsError('INVALID_INPUT', '実施者を確認できません。', 400);
  }
  return jsonResponse(await callServerTx(service, 'server_tx_correct_task_actual', {
    p_actor_id: actorId, p_operation_id: operationId, p_task_id: body.task_id,
    p_performer_actor_ref_ids: (refs ?? []).map((ref) => ref.id), p_expected_revision: body.expected_revision,
  }));
}));
