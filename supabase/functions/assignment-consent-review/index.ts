import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { FamilyOpsError } from '../_shared/errors.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';

Deno.serve(withUserMutationHandler(async (req) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const client = createServiceRoleClient();
  if (body.action === 'read') {
    return jsonResponse(await callServerTx(client, 'server_read_assignment_review_v1', { p_actor_id: actorId }));
  }
  if (!['keep', 'stop', 'optional'].includes(String(body.action)) || typeof body.task_definition_id !== 'string') {
    throw new FamilyOpsError('INVALID_INPUT', 'review action and task definition are required', 400);
  }
  return jsonResponse(await callServerTx(client, 'server_tx_review_assignment_v1', {
    p_actor_id: actorId, p_operation_id: requireOperationId(body), p_definition_id: body.task_definition_id, p_action: body.action,
  }));
}));
