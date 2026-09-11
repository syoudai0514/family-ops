import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';
import { requestTransitionArgs } from '../_shared/requestTransition.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  body.action = 'accept';
  return jsonResponse(await callServerTx(createServiceRoleClient(), 'server_tx_transition_request_v2',
    requestTransitionArgs(actorId, operationId, body, 'pwa')));
}));
