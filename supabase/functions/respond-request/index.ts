// verify_jwt=true. Checking/consulting are canonical request-attempt states;
// this endpoint never accepts or changes an assignment as a side effect.
import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  if (typeof body.request_id !== 'string' || !['checking', 'consult'].includes(String(body.response_action))) {
    throw new FamilyOpsError('INVALID_INPUT', 'request_id and response_action are required', 400);
  }
  return jsonResponse(await callServerTx(createServiceRoleClient(), 'server_tx_respond_request', {
    p_actor_id: actorId, p_operation_id: operationId, p_request_id: body.request_id,
    p_response_action: body.response_action,
  }));
}));
