import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  if (!Array.isArray(body.terms)) throw new FamilyOpsError('INVALID_INPUT', 'terms is required', 400);
  return jsonResponse(await callServerTx(createServiceRoleClient(), 'server_tx_replace_household_terminology', {
    p_actor_id: actorId, p_operation_id: operationId, p_terms: body.terms,
  }));
}));
