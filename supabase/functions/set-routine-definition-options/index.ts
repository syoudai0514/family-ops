import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { FamilyOpsError } from '../_shared/errors.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';

Deno.serve(withUserMutationHandler(async (req) => {
  const actorId = await requireUserActor(req); const body = await readJsonBody(req);
  const id = body.task_definition_id;
  if (typeof id !== 'string' || typeof body.enabled !== 'boolean' || typeof body.include_in_routine_line !== 'boolean') throw new FamilyOpsError('INVALID_INPUT', 'routine options are required', 400);
  return jsonResponse(await callServerTx(createServiceRoleClient(), 'server_tx_set_routine_definition_options', {
    p_actor_id: actorId, p_operation_id: requireOperationId(body), p_task_definition_id: id, p_enabled: body.enabled, p_include_in_routine_line: body.include_in_routine_line,
  }));
}));
