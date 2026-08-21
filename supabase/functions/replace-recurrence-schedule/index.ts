import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { FamilyOpsError } from '../_shared/errors.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';

Deno.serve(
  withUserMutationHandler(async (req: Request) => {
    const actorId = await requireUserActor(req);
    const body = await readJsonBody(req);
    const operationId = requireOperationId(body);
    const replacements = body.replacements;
    if (!Array.isArray(replacements) || replacements.length === 0) {
      throw new FamilyOpsError('INVALID_INPUT', 'replacements must be a non-empty array', 400);
    }
    const result = await callServerTx<{ household_id: string; replaced: number }>(
      createServiceRoleClient(),
      'server_tx_replace_recurrence_schedule',
      { p_actor_id: actorId, p_operation_id: operationId, p_replacements: replacements },
    );
    return jsonResponse(result);
  }),
);
