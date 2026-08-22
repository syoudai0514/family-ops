import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { FamilyOpsError } from '../_shared/errors.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';

const STEPS = ['morning_preparation', 'connections', 'notifications', 'week_preview'] as const;

Deno.serve(
  withUserMutationHandler(async (req: Request) => {
    const actorId = await requireUserActor(req);
    const body = await readJsonBody(req);
    const operationId = requireOperationId(body);
    const step = body.step;
    if (typeof step !== 'string' || !STEPS.includes(step as (typeof STEPS)[number])) {
      throw new FamilyOpsError('INVALID_INPUT', 'unknown onboarding step', 400);
    }
    const result = await callServerTx<{ household_id: string; step: string; completed: true }>(
      createServiceRoleClient(),
      'server_tx_complete_onboarding_step',
      { p_actor_id: actorId, p_operation_id: operationId, p_step: step },
    );
    return jsonResponse(result);
  }),
);
