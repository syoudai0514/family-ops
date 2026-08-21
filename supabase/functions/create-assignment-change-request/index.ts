import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req); const body = await readJsonBody(req); const operationId = requireOperationId(body);
  const taskId = body.task_id; const recipientUserId = body.recipient_user_id; const scope = body.scope;
  if (typeof taskId !== 'string' || typeof recipientUserId !== 'string' || !['once', 'this_week'].includes(String(scope))) throw new FamilyOpsError('INVALID_INPUT', 'task_id, recipient_user_id and scope are required', 400);
  const result = await callServerTx(createServiceRoleClient(), 'server_tx_create_assignment_change_request', { p_actor_id: actorId, p_operation_id: operationId, p_task_id: taskId, p_recipient_user_id: recipientUserId, p_shared_message: typeof body.shared_message === 'string' ? body.shared_message : null, p_scope: scope });
  return jsonResponse(result);
}));
