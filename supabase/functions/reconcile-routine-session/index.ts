// verify_jwt=true. Exact server-resolved routine snapshot plus immediate Q59 undo.
import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  const client = createServiceRoleClient();

  if (body.action === 'undo') {
    if (typeof body.target_operation_id !== 'string' || body.target_operation_id.length === 0) {
      throw new FamilyOpsError('INVALID_INPUT', 'target_operation_id is required', 400);
    }
    return jsonResponse(await callServerTx(client, 'server_tx_undo_routine_reconciliation', {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_target_operation_id: body.target_operation_id,
    }));
  }

  if (typeof body.session_id !== 'string' || !['all_done', 'mostly_done', 'individual'].includes(String(body.response_kind))) {
    throw new FamilyOpsError('INVALID_INPUT', 'session_id and response_kind are required', 400);
  }
  return jsonResponse(await callServerTx(client, 'server_tx_reconcile_routine_session_v2', {
    p_actor_id: actorId,
    p_operation_id: operationId,
    p_session_id: body.session_id,
    p_response_kind: body.response_kind,
  }));
}));
