// verify_jwt=true. The client supplies only the session and selected response;
// the database derives the exact active snapshot and excludes waiting rows.
import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  if (typeof body.session_id !== 'string' || !['all_done', 'mostly_done', 'individual'].includes(String(body.response_kind))) {
    throw new FamilyOpsError('INVALID_INPUT', 'session_id and response_kind are required', 400);
  }
  return jsonResponse(await callServerTx(createServiceRoleClient(), 'server_tx_reconcile_routine_session', {
    p_actor_id: actorId, p_operation_id: operationId, p_session_id: body.session_id,
    p_response_kind: body.response_kind,
  }));
}));
